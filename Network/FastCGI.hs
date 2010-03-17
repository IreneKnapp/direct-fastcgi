{-# LANGUAGE TypeSynonymInstances #-}
module Main (
             main,
             -- * The monad
             FastCGI,
             FastCGIMonad,
             FastCGIState,
             getFastCGIState,
             
             -- * Accepting connections
             acceptLoop,
             concurrentAcceptLoop,
             
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


main :: IO ()
main = do
  acceptLoop main'


main' :: FastCGI ()
main' = do
  FastCGIState { logHandle = logHandle, socket = socket, peer = peer } <- getFastCGIState
  liftIO $ hPutStrLn logHandle $ "Connection: " ++ (show socket) ++ " " ++ (show peer)
  liftIO $ hFlush logHandle
  return ()


-- | Takes a handler and sequentially accepts connections from the web server, invoking
--   the handler inside the 'FastCGI' monad for each one.
--   
--   Note that although there is no mechanism to substitute another type of monad for
--   FastCGI, you can enter your own monad within the handler, much as you would enter
--   your own monad within IO.  You simply have to implement the 'FastCGIMonad' class.
--   
--   Any exceptions not caught within the handler are caught by 'acceptLoop', and cause
--   the termination of that handler, but not of the accept loop.  Furthermore, the
--   exception is logged through the FastCGI protocol if at all possible.
--   
--   In the event that the program was not invoked according to the FastCGI protocol,
--   returns.
acceptLoop
    :: (FastCGI ())
    -- ^ A handler which is invoked once for each incoming connection.
    -> IO ()
    -- ^ Never actually returns.
acceptLoop handler = concurrentAcceptLoop (\handler -> do
                                             handler
                                             myThreadId)
                                          handler


-- | Takes a forking primitive, such as 'forkIO' or 'forkOS', and a handler, and
--   concurrently accepts connections from the web server, forking with the primitive
--   and invoking the handler in the forked thread inside the 'FastCGI' monad for each
--   one.
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
concurrentAcceptLoop
    :: (IO () -> IO ThreadId)
    -- ^ A forking primitive, typically either 'forkIO' or 'forkOS'.
    -> (FastCGI ())
    -- ^ A handler which is invoked once for each incoming connection.
    -> IO ()
    -- ^ Never actually returns.
concurrentAcceptLoop fork handler = do
  logHandle <- openFile "/tmp/log.txt" AppendMode
  maybeListenSocket <- createListenSocket
  webServerAddresses <- computeWebServerAddresses
  hPutStrLn logHandle $ "Web server addresses: " ++ (show webServerAddresses)
  case maybeListenSocket of
    Nothing -> return ()
    Just listenSocket -> do
      let concurrentAcceptLoop' = do
            (socket, peer) <- Network.accept listenSocket
            let state = FastCGIState {
                           logHandle = logHandle,
                           webServerAddresses = webServerAddresses,
                           socket = socket,
                           peer = peer
                         }
            fork $ runFastCGI handler state
            concurrentAcceptLoop'
      concurrentAcceptLoop'


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


runFastCGI :: (FastCGI ()) -> FastCGIState -> IO ()
runFastCGI handler state = do
  Exception.catch (flip runReaderT state $ do
                     addressValid <- validateWebServerAddress
                     case addressValid of
                       False -> do
                         FastCGIState { peer = peer } <- getFastCGIState
                         logFastCGI $ "Ignoring connection from invalid address: "
                                    ++ (show peer)
                       True -> handler)
                  (\error -> flip runReaderT state $ do
                     logFastCGI $ "Uncaught exception: "
                                  ++ (show (error :: Exception.SomeException)))
  Exception.catch (Network.sClose $ socket state)
                  (\error -> do
                     return $ error :: IO Exception.SomeException
                     return ())
  return ()


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


logFastCGI :: (FastCGIMonad m) => String -> m ()
logFastCGI message = do
  FastCGIState { logHandle = logHandle } <- getFastCGIState
  liftIO $ hPutStrLn logHandle $ "LOG MESSAGE: " ++ message
  liftIO $ hFlush logHandle
