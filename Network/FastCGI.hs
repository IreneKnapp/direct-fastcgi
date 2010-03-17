{-# LANGUAGE TypeSynonymInstances #-}
module Main (
             main,
             -- * The monad
             FastCGI,
             FastCGIMonad,
             FastCGIState,
             getFastCGIState,
             
             -- * Accepting requests
             acceptLoop,
             
             -- * Logging
             logFastCGI
            )
    where

import Control.Concurrent
import qualified Control.Exception as Exception
import Control.Monad.Reader
import qualified Data.ByteString as BS
import Data.List
import Foreign.C.Error
import GHC.IO.Exception (IOErrorType(..))
import qualified Network.Socket as Network hiding (send, sendTo, recv, recvFrom)
import qualified Network.Socket.ByteString as Network
import Prelude hiding (catch)
import System.Environment
import System.IO.Error (ioeGetErrorType)
import qualified System.IO.Error as System

import System.IO


-- | An opaque type representing the state of a single connection from the web server.
data FastCGIState = FastCGIState {
      logHandle :: Handle,
      webServerAddresses :: Maybe [Network.HostAddress],
      socket :: Network.Socket,
      peer :: Network.SockAddr
    }


-- | The monad within which each single connection from the web server is handled.
type FastCGI = ReaderT FastCGIState IO


-- | The class of monads within which the FastCGI calls are valid.  You may wish to
--   create your own monad implementing this class.
class (MonadIO m) => FastCGIMonad m where
    getFastCGIState :: m FastCGIState


instance FastCGIMonad FastCGI where
    getFastCGIState = ask


data Record = Record {
      recordType :: RecordType,
      recordRequestID :: Int,
      recordContent :: BS.ByteString
    } deriving (Show)


data RecordType = BeginRequestRecord
                | AbortRequestRecord
                | EndRequestRecord
                | ParamsRecord
                | StdinRecord
                | StdoutRecord
                | StderrRecord
                | DataRecord
                | GetValuesRecord
                | GetValuesResultRecord
                  deriving (Eq, Show)
instance Enum RecordType where
    toEnum 1 = BeginRequestRecord
    toEnum 2 = AbortRequestRecord
    toEnum 3 = EndRequestRecord
    toEnum 4 = ParamsRecord
    toEnum 5 = StdinRecord
    toEnum 6 = StdoutRecord
    toEnum 7 = StderrRecord
    toEnum 8 = DataRecord
    toEnum 9 = GetValuesRecord
    toEnum 10 = GetValuesResultRecord
    fromEnum BeginRequestRecord = 1
    fromEnum AbortRequestRecord = 2
    fromEnum EndRequestRecord = 3
    fromEnum ParamsRecord = 4
    fromEnum StdinRecord = 5
    fromEnum StdoutRecord = 6
    fromEnum StderrRecord = 7
    fromEnum DataRecord = 8
    fromEnum GetValuesRecord = 9
    fromEnum GetValuesResultRecord = 10


main :: IO ()
main = do
  acceptLoop forkIO main'


main' :: FastCGI ()
main' = do
  logFastCGI $ "In the handler."
  return ()


-- | Takes a forking primitive, such as 'forkIO' or 'forkOS', and a handler, and
--   concurrently accepts requests from the web server, forking with the primitive
--   and invoking the handler in the forked thread inside the 'FastCGI' monad for each
--   one.
--   
--   It is valid to use a custom forking primitive, such as one that attempts to pool
--   OS threads, but the primitive must actually provide concurrency - otherwise there
--   will be a deadlock.  There is no support for single-threaded operation.
--   
--   Note that although there is no mechanism to substitute another type of monad for
--   FastCGI, you can enter your own monad within the handler, much as you would enter
--   your own monad within IO.  You simply have to implement the 'FastCGIMonad' class.
--   
--   Any exceptions not caught within the handler are caught by 'concurrentAcceptLoop',
--   and cause the termination of that handler, but not of the accept loop.
--   Furthermore, the exception is logged through the FastCGI protocol if at all
--   possible.
--   
--   In the event that the program was not invoked according to the FastCGI protocol,
--   returns.
acceptLoop
    :: (IO () -> IO ThreadId)
    -- ^ A forking primitive, typically either 'forkIO' or 'forkOS'.
    -> (FastCGI ())
    -- ^ A handler which is invoked once for each incoming connection.
    -> IO ()
    -- ^ Never actually returns.
acceptLoop fork handler = do
  logHandle <- openFile "/tmp/log.txt" AppendMode
  maybeListenSocket <- createListenSocket
  webServerAddresses <- computeWebServerAddresses
  hPutStrLn logHandle $ "Web server addresses: " ++ (show webServerAddresses)
  case maybeListenSocket of
    Nothing -> return ()
    Just listenSocket -> do
      let acceptLoop' = do
            (socket, peer) <- Network.accept listenSocket
            let state = FastCGIState {
                           logHandle = logHandle,
                           webServerAddresses = webServerAddresses,
                           socket = socket,
                           peer = peer
                         }
            flip runReaderT state $ do
              addressValid <- validateWebServerAddress
              case addressValid of
                False -> do
                  FastCGIState { peer = peer } <- getFastCGIState
                  logFastCGI $ "Ignoring connection from invalid address: "
                               ++ (show peer)
                True -> requestLoop fork handler
            acceptLoop'
      acceptLoop'


createListenSocket :: IO (Maybe Network.Socket)
createListenSocket = do
  listenSocket <- Network.mkSocket 0
                                   Network.AF_INET
                                   Network.Stream
                                   Network.defaultProtocol
                                   Network.Listening
  -- Notice that we do AF_INET even though AF_UNSPEC would be more honest, because
  -- we need to call getPeerName which needs to know how big a sockaddr to allow for.
  -- This should work even though the socket could, for all we know, be an ipv6 socket
  -- with a larger sockaddr, because that check hopefully happens after the check for
  -- the case we care about, which is that the socket is not connected and therefore
  -- has no peer name.
  System.catch (do
                 Network.getPeerName listenSocket
                 return Nothing)
               (\error -> do
                 if ioeGetErrorType error == InvalidArgument
                   then do
                     -- Since we need to know the specific error code, not just the
                     -- logical mapping of it, we need to actually drill down and check
                     -- errno.  Otherwise we can't distinguish "it doesn't have a peer
                     -- name because it's a listening socket" from "it doesn't have a
                     -- peer name because it's not a socket at all".
                     errno <- getErrno
                     if errno == eNOTCONN
                       then return $ Just listenSocket
                       else return Nothing
                   else return Nothing)


computeWebServerAddresses :: IO (Maybe [Network.HostAddress])
computeWebServerAddresses = do
  environment <- getEnvironment
  System.catch (do
                 string <- getEnv "FCGI_WEB_SERVER_ADDRS"
                 let split [] = []
                     split string = case elemIndex ',' string of
                                      Nothing -> [string]
                                      Just index ->
                                          let (first, rest) = splitAt index string
                                          in first : (split $ drop 1 rest)
                     splitString = split string
                 addresses <- mapM Network.inet_addr splitString
                 return $ Just addresses)
               (\error -> do
                 if System.isDoesNotExistError error
                   then return Nothing
                   else System.ioError error)


validateWebServerAddress :: (FastCGIMonad m) => m Bool
validateWebServerAddress = do
  FastCGIState { webServerAddresses = maybeWebServerAddresses, peer = peer }
      <- getFastCGIState
  case maybeWebServerAddresses of
    Nothing -> return True
    Just webServerAddresses
        -> return $ flip any webServerAddresses
                         (\webServerAddress -> case peer of
                             Network.SockAddrInet _ peerAddress
                                 -> webServerAddress == peerAddress
                             _ -> False)


requestLoop :: (IO () -> IO ThreadId) -> (FastCGI ()) -> FastCGI ()
requestLoop fork handler = do
  maybeRecord <- recvRecord
  case maybeRecord of
    Nothing -> do
      FastCGIState { socket = socket } <- getFastCGIState
      liftIO $ Exception.catch (Network.sClose socket)
                               (\error -> do
                                  return $ error :: IO Exception.IOException
                                  return ())
      return ()
    Just request -> do
      logFastCGI $ show request
      state <- getFastCGIState
      liftIO $ fork $ do
        Exception.catch (runReaderT handler state)
                        (\error -> flip runReaderT state $ do
                           logFastCGI $ "Uncaught exception: "
                                        ++ (show (error :: Exception.SomeException)))
      requestLoop fork handler


recvRecord :: (FastCGIMonad m) => m (Maybe Record)
recvRecord = do
  FastCGIState { socket = socket } <- getFastCGIState
  byteString <- liftIO $ recvAll socket 8
  case BS.length byteString of
    8 -> do
      let recordVersion = BS.index byteString 0
          recordTypeCode = fromIntegral $ BS.index byteString 1
          recordRequestIDB1 = BS.index byteString 2
          recordRequestIDB0 = BS.index byteString 3
          recordRequestID = (fromIntegral recordRequestIDB1) * 256
                            + (fromIntegral recordRequestIDB0)
          recordContentLengthB1 = BS.index byteString 4
          recordContentLengthB0 = BS.index byteString 5
          recordContentLength = (fromIntegral recordContentLengthB1) * 256
                                + (fromIntegral recordContentLengthB0)
          recordPaddingLength = BS.index byteString 6
      if recordVersion /= 1
        then do
          logFastCGI $ "Record header of unrecognized version: "
                       ++ (show recordVersion)
          return Nothing
        else do
          let recordType = toEnum recordTypeCode
          recordContent <- liftIO $ recvAll socket recordContentLength
          liftIO $ recvAll socket $ fromIntegral recordPaddingLength
          return $ Just $ Record {
                              recordType = recordType,
                              recordRequestID = recordRequestID,
                              recordContent = recordContent
                            }
    _ -> return Nothing


recvAll :: Network.Socket -> Int -> IO BS.ByteString
recvAll socket totalSize = do
  if totalSize == 0
    then return BS.empty
    else do
      byteString <- Network.recv socket totalSize
      case BS.length byteString of
        0 -> return byteString
        receivedSize | receivedSize == totalSize -> return byteString
                     | otherwise -> do
                                  restByteString
                                      <- recvAll socket $ totalSize - receivedSize
                                  return $ BS.append byteString restByteString


-- | Logs a message using the web server's logging facility.
logFastCGI :: (FastCGIMonad m) => String -> m ()
logFastCGI message = do
  FastCGIState { logHandle = logHandle } <- getFastCGIState
  liftIO $ hPutStrLn logHandle message
  liftIO $ hFlush logHandle
