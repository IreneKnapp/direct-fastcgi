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
             logFastCGI,
             
             -- * Request information
             -- | It is common practice for web servers to make their own extensions to
             --   the CGI/1.1 set of defined variables.  For example, @REMOTE_PORT@ is
             --   not defined by the specification, but often seen in the wild.
             --   Therefore, there are two levels of call available; defined
             --   variables may be interrogated directly, and in addition, there
             --   are higher-level calls which give convenient names and types to the
             --   same information.
             Header(..),
             
             -- * Request content data
             -- | At the moment the handler is invoked, all request headers have been
             --   received, but content data has not necessarily been.  Requests to read
             --   content data block the handler (but not other concurrent handlers)
             --   until there is enough data in the buffer to satisfy them, or until
             --   timeout where applicable.
             
             -- * Response information and content data
             -- | When the handler is first invoked, neither response headers nor
             --   content data have been sent to the client.  Setting of response
             --   headers is lazy, merely setting internal variables, until something
             --   forces them to be output.  For example, attempting to send content
             --   data will force response headers to be output first.  It is not
             --   necessary to close the output stream explicitly, but it may be
             --   desirable, for example to continue processing after returning results
             --   to the user.
             --   
             --   There is no reason that client scripts cannot use any encoding they
             --   wish, including the chunked encoding, if they have set appropriate
             --   headers.  This package, however, does not explicitly support that,
             --   because client scripts can easily implement it for themselves.
             --   
             --   At the start of each request, the response status is set to @200 OK@
             --   and the only response header set is @Content-Type: text/html@.  These
             --   may be overridden by later calls, at any time before headers have
             --   been sent.
             
             -- * Cookies
             -- | Cookies may also be manipulated through HTTP headers directly; the
             --   functions here are provided only as a convenience.
             Cookie(..)
            )
    where

import Control.Concurrent
import qualified Control.Exception as Exception
import Control.Monad.Reader
import Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.UTF8 as BS (toString, fromString)
import Data.Char
import Data.List
import qualified Data.Map as Map
import Data.Maybe
import Data.Word
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
      peer :: Network.SockAddr,
      requestChannelMapMVar :: MVar (Map.Map Int (Chan Record)),
      request :: Maybe Request
    }


data Request = Request {
      requestID :: Int,
      requestChannel :: Chan Record,
      paramsStreamBufferMVar :: MVar BS.ByteString,
      requestVariableMapMVar :: MVar (Map.Map String String),
      requestHeaderMapMVar :: MVar (Map.Map Header String),
      requestCookieMapMVar :: MVar (Map.Map String Cookie),
      responseStatusMVar :: MVar Int,
      responseHeaderMapMVar :: MVar (Map.Map Header String),
      responseHeadersSentMVar :: MVar Bool
    }


data Cookie = Cookie {
      cookieName :: String,
      cookieValue :: String,
      cookieVersion :: Int,
      cookiePath :: Maybe String,
      cookieDomain :: Maybe String
    } deriving (Show)


-- | The monad within which each single connection from the web server is handled.
type FastCGI = ReaderT FastCGIState IO


-- | The class of monads within which the FastCGI calls are valid.  You may wish to
--   create your own monad implementing this class.
class (MonadIO m) => FastCGIMonad m where
    -- | Returns the opaque 'FastCGIState' object representing the state of the
    --   FastCGI client.
    getFastCGIState
        :: m FastCGIState


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
                | UnknownTypeRecord
                | OtherRecord Int
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
    toEnum 11 = UnknownTypeRecord
    toEnum code = OtherRecord code
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
    fromEnum UnknownTypeRecord = 11


main :: IO ()
main = do
  acceptLoop forkIO main'


main' :: FastCGI ()
main' = do
  logFastCGI $ "In the handler."
  state <- getFastCGIState
  requestVariableMap <- liftIO $ readMVar $ requestVariableMapMVar $ fromJust $ request state
  requestHeaderMap <- liftIO $ readMVar $ requestHeaderMapMVar $ fromJust $ request state
  requestCookieMap <- liftIO $ readMVar $ requestCookieMapMVar $ fromJust $ request state
  logFastCGI $ (show requestVariableMap)
  logFastCGI $ (show requestHeaderMap)
  logFastCGI $ (show requestCookieMap)
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
  case maybeListenSocket of
    Nothing -> return ()
    Just listenSocket -> do
      let acceptLoop' = do
            (socket, peer) <- Network.accept listenSocket
            requestChannelMapMVar <- newMVar $ Map.empty
            let state = FastCGIState {
                           logHandle = logHandle,
                           webServerAddresses = webServerAddresses,
                           socket = socket,
                           peer = peer,
                           requestChannelMapMVar = requestChannelMapMVar,
                           request = Nothing
                         }
            flip runReaderT state $ do
              addressValid <- validateWebServerAddress
              case addressValid of
                False -> do
                  FastCGIState { peer = peer } <- getFastCGIState
                  logFastCGI $ "Ignoring connection from invalid address: "
                               ++ (show peer)
                True -> outsideRequestLoop fork handler
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


outsideRequestLoop :: (IO () -> IO ThreadId) -> (FastCGI ()) -> FastCGI ()
outsideRequestLoop fork handler = do
  maybeRecord <- recvRecord
  case maybeRecord of
    Nothing -> do
      FastCGIState { socket = socket } <- getFastCGIState
      liftIO $ Exception.catch (Network.sClose socket)
                               (\error -> do
                                  return $ error :: IO Exception.IOException
                                  return ())
      return ()
    Just record -> do
      case recordType record of
        BeginRequestRecord -> do
          state <- getFastCGIState
          requestChannel <- liftIO $ newChan
          requestChannelMap <- liftIO $ takeMVar $ requestChannelMapMVar state
          paramsStreamBufferMVar <- liftIO $ newMVar $ BS.empty
          requestVariableMapMVar <- liftIO $ newMVar $ Map.empty
          requestHeaderMapMVar <- liftIO $ newMVar $ Map.empty
          requestCookieMapMVar <- liftIO $ newMVar $ Map.empty
          responseStatusMVar <- liftIO $ newMVar $ 200
          responseHeaderMapMVar <- liftIO $ newMVar $ Map.empty
          responseHeadersSentMVar <- liftIO $ newMVar $ False
          let requestChannelMap' = Map.insert (recordRequestID record)
                                              requestChannel
                                              requestChannelMap
              request = Request {
                                requestID = recordRequestID record,
                                requestChannel = requestChannel,
                                paramsStreamBufferMVar = paramsStreamBufferMVar,
                                requestVariableMapMVar = requestVariableMapMVar,
                                requestHeaderMapMVar = requestHeaderMapMVar,
                                requestCookieMapMVar = requestCookieMapMVar,
                                responseStatusMVar = responseStatusMVar,
                                responseHeaderMapMVar = responseHeaderMapMVar,
                                responseHeadersSentMVar = responseHeadersSentMVar
                              }
              state' = state { request = Just request }
          liftIO $ putMVar (requestChannelMapMVar state) requestChannelMap'
          liftIO $ fork $ do
            Exception.catch (runReaderT (insideRequestLoop handler) state')
                            (\error -> flip runReaderT state' $ do
                               logFastCGI $ "Uncaught exception: "
                                            ++ (show (error :: Exception.SomeException)))
          return ()
        OtherRecord unknownCode -> do
          sendRecord $ Record {
                               recordType = UnknownTypeRecord,
                               recordRequestID = 0,
                               recordContent = BS.pack [fromIntegral unknownCode,
                                                        0, 0, 0, 0, 0, 0, 0]
                             }
        GetValuesRecord -> do
          logFastCGI $ "Get values record: " ++ (show record)
        _ -> do
          state <- getFastCGIState
          requestChannelMap <- liftIO $ readMVar $ requestChannelMapMVar state
          let requestID = recordRequestID record
              maybeRequestChannel = Map.lookup requestID requestChannelMap
          case maybeRequestChannel of
            Nothing ->
                logFastCGI $ "Ignoring record for unknown request ID " ++ (show requestID)
            Just requestChannel -> liftIO $ writeChan requestChannel record
      outsideRequestLoop fork handler


insideRequestLoop :: (FastCGI ()) -> FastCGI ()
insideRequestLoop handler = do
  FastCGIState { request = Just request } <- getFastCGIState
  record <- liftIO $ readChan $ requestChannel request
  case recordType record of
    ParamsRecord -> do
      case BS.length $ recordContent record of
        0 -> do
          handler
        _ -> do
          buffer <- liftIO $ takeMVar $ paramsStreamBufferMVar request
          let bufferWithNewData = BS.append buffer $ recordContent record
              takeUntilEmpty bufferTail = do
                let maybeNameValuePair = takeNameValuePair bufferTail
                case maybeNameValuePair of
                  Nothing -> liftIO $ putMVar (paramsStreamBufferMVar request) bufferTail
                  Just ((name, value), bufferTail') -> do
                    let name' = BS.toString name
                        value' = BS.toString value
                    processRequestVariable name' value'
                    takeUntilEmpty bufferTail'
          takeUntilEmpty bufferWithNewData
    _ -> do
      logFastCGI $ "inside loop: " ++ (show record)
  insideRequestLoop handler


processRequestVariable :: String -> String -> FastCGI ()
processRequestVariable name value = do
  state <- getFastCGIState
  requestVariableMap
      <- liftIO $ takeMVar $ requestVariableMapMVar $ fromJust $ request state
  let requestVariableMap' = Map.insert name value requestVariableMap
  liftIO $ putMVar (requestVariableMapMVar $ fromJust $ request state)
                   requestVariableMap'
  let maybeHeader = requestVariableNameToHeader name
  case maybeHeader of
    Nothing -> return ()
    Just header -> do
      processRequestHeader header value


processRequestHeader :: Header -> String -> FastCGI ()
processRequestHeader header value = do
  state <- getFastCGIState
  requestHeaderMap
      <- liftIO $ takeMVar $ requestHeaderMapMVar $ fromJust $ request state
  let requestHeaderMap' = Map.insert header value requestHeaderMap
  liftIO $ putMVar (requestHeaderMapMVar $ fromJust $ request state) requestHeaderMap'
  case header of
    HttpCookie -> do
      processCookies value
    _ -> return ()


processCookies :: String -> FastCGI ()
processCookies value = do
  state <- getFastCGIState
  requestCookieMap
      <- liftIO $ takeMVar $ requestCookieMapMVar $ fromJust $ request state
  let updateCookieMap cookieMap (cookie:rest)
          = updateCookieMap (Map.insert (cookieName cookie) cookie cookieMap)
                            rest
      updateCookieMap cookieMap [] = cookieMap
      requestCookieMap' = updateCookieMap requestCookieMap $ parseCookies value
  liftIO $ putMVar (requestCookieMapMVar $ fromJust $ request state) requestCookieMap'


parseCookies :: String -> [Cookie]
parseCookies value =
  let findSeparator string
          = let quotePoint = if (length string > 0) && (string !! 0 == '"')
                               then 1 + (findBalancingQuote $ drop 1 string)
                               else 0
                maybeSemicolonPoint
                    = case (findIndex (\c -> (c == ';') || (c == ','))
                                          $ drop quotePoint string)
                      of Nothing -> Nothing
                         Just index -> Just $ index + quotePoint
            in maybeSemicolonPoint
      findBalancingQuote string
          = let consume accumulator ('\\' : c : rest) = consume (accumulator + 2) rest
                consume accumulator ('"' : rest) = accumulator
                consume accumulator (c : rest) = consume (accumulator + 1) rest
                consume accumulator "" = accumulator
            in consume 0 string
      split [] = []
      split string = case findSeparator string of
                       Nothing -> [string]
                       Just index ->
                         let (first, rest) = splitAt index string
                         in first : (split $ drop 1 rest)
      splitNameValuePair string = case elemIndex '=' (filterNameValuePair string) of
                                    Nothing -> (string, "")
                                    Just index -> let (first, rest)
                                                          = splitAt index
                                                                    (filterNameValuePair
                                                                      string)
                                                  in (first, filterValue (drop 1 rest))
      filterNameValuePair string
          = reverse $ dropWhile isSpace $ reverse $ dropWhile isSpace string
      filterValue string = if (length string > 0) && ((string !! 0) == '"')
                             then take (findBalancingQuote $ drop 1 string)
                                       $ drop 1 string
                             else string
      pairs = map splitNameValuePair $ split value
      (version, pairs') = case pairs of
                                 ("$Version", versionString) : rest
                                     -> case parseInt versionString of
                                          Nothing -> (0, rest)
                                          Just version -> (version, rest)
                                 _ -> (0, pairs)
      takeCookie pairs = case pairs of
                           (name, value) : pairs'
                               | (length name > 0) && (take 1 name /= "$")
                                    -> let (maybePath, maybeDomain, pairs'')
                                               = takePathAndDomain pairs'
                                       in (Cookie {
                                             cookieName = name,
                                             cookieValue = value,
                                             cookieVersion = version,
                                             cookiePath = maybePath,
                                             cookieDomain = maybeDomain
                                           }
                                           : takeCookie pairs'')
                           _ : pairs' -> takeCookie pairs'
                           [] -> []
      takePathAndDomain pairs = let (maybePath, pairs')
                                        = case pairs of ("$Path", path) : rest
                                                            -> (Just path, rest)
                                                        _ -> (Nothing, pairs)
                                    (maybeDomain, pairs'')
                                        = case pairs' of ("$Domain", domain) : rest
                                                             -> (Just domain, rest)
                                                         _ -> (Nothing, pairs')
                                in (maybePath, maybeDomain, pairs'')
  in takeCookie pairs'


parseInt :: String -> Maybe Int
parseInt string =
    if (length string > 0) && (all isDigit string)
      then Just $ let accumulate "" accumulator = accumulator
                      accumulate (n:rest) accumulator
                                 = accumulate rest $ accumulator * 10 + digitToInt n
                  in accumulate string 0
      else Nothing


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


sendRecord :: (FastCGIMonad m) => Record -> m ()
sendRecord record = do
  FastCGIState { socket = socket } <- getFastCGIState
  let recordRequestIDB0 = fromIntegral $ recordRequestID record `mod` 256
      recordRequestIDB1 = fromIntegral $ (recordRequestID record `div` 256) `mod` 256
      recordContentLength = BS.length $ recordContent record
      recordContentLengthB0 = fromIntegral $ recordContentLength `mod` 256
      recordContentLengthB1 = fromIntegral $ (recordContentLength `div` 256) `mod` 256
      headerByteString = BS.pack [1,
                                  fromIntegral $ fromEnum $ recordType record,
                                  recordRequestIDB1,
                                  recordRequestIDB0,
                                  recordContentLengthB1,
                                  recordContentLengthB0,
                                  0,
                                  0]
      byteString = BS.append headerByteString $ recordContent record
  liftIO $ Network.sendAll socket byteString


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


takeLength :: BS.ByteString -> Maybe (Int, BS.ByteString)
takeLength byteString
    = if BS.length byteString < 1
        then Nothing
        else let firstByte = BS.index byteString 0
                 threeMoreComing = (firstByte .&. 0x80) == 0x80
             in if threeMoreComing
                  then if BS.length byteString < 4
                         then Nothing
                         else let secondByte = BS.index byteString 1
                                  thirdByte = BS.index byteString 2
                                  fourthByte = BS.index byteString 3
                                  decoded = ((fromIntegral $ firstByte .&. 0x7F)
                                             `shiftL` 24)
                                            + (fromIntegral secondByte `shiftL` 16)
                                            + (fromIntegral thirdByte `shiftL` 8)
                                            + (fromIntegral fourthByte)
                              in Just (decoded, BS.drop 4 byteString)
                  else Just (fromIntegral firstByte, BS.drop 1 byteString)


takeNameValuePair :: BS.ByteString
                  -> Maybe ((BS.ByteString, BS.ByteString), BS.ByteString)
takeNameValuePair byteString
    = let maybeNameLength = takeLength byteString
      in case maybeNameLength of
           Nothing -> Nothing
           Just (nameLength, byteString')
             -> let maybeValueLength = takeLength byteString'
                in case maybeValueLength of
                     Nothing -> Nothing
                     Just (valueLength, byteString'')
                       -> let name = BS.take nameLength byteString''
                              byteString''' = BS.drop nameLength byteString''
                              value = BS.take valueLength byteString'''
                              byteString'''' = BS.drop valueLength byteString'''
                          in Just ((name, value), byteString'''')


-- | Logs a message using the web server's logging facility.
logFastCGI :: (FastCGIMonad m) => String -> m ()
logFastCGI message = do
  FastCGIState { logHandle = logHandle } <- getFastCGIState
  liftIO $ hPutStrLn logHandle message
  liftIO $ hFlush logHandle


-- | Headers are classified by HTTP/1.1 as request headers, response headers, or
--   entity headers.
data Header
    -- | Request headers
    = HttpAccept
    | HttpAcceptCharset
    | HttpAcceptEncoding
    | HttpAcceptLanguage
    | HttpAuthorization
    | HttpExpect
    | HttpFrom
    | HttpHost
    | HttpIfMatch
    | HttpIfModifiedSince
    | HttpIfNoneMatch
    | HttpIfRange
    | HttpIfUnmodifiedSince
    | HttpMaxForwards
    | HttpProxyAuthorization
    | HttpRange
    | HttpReferer
    | HttpTE
    | HttpUserAgent
    -- | Response headers
    | HttpAcceptRanges
    | HttpAge
    | HttpETag
    | HttpLocation
    | HttpProxyAuthenticate
    | HttpRetryAfter
    | HttpServer
    | HttpVary
    | HttpWWWAuthenticate
    -- | Entity headers
    | HttpAllow
    | HttpContentEncoding
    | HttpContentLanguage
    | HttpContentLength
    | HttpContentLocation
    | HttpContentMD5
    | HttpContentRange
    | HttpContentType
    | HttpExpires
    | HttpLastModified
    | HttpExtensionHeader String
    -- | Nonstandard headers
    | HttpConnection
    | HttpCookie
    | HttpSetCookie
      deriving (Eq, Ord, Show)


data HeaderType = RequestHeader
                | ResponseHeader
                | EntityHeader
                  deriving (Eq, Show)


headerType :: Header -> HeaderType
headerType HttpAccept = RequestHeader
headerType HttpAcceptCharset = RequestHeader
headerType HttpAcceptEncoding = RequestHeader
headerType HttpAcceptLanguage = RequestHeader
headerType HttpAuthorization = RequestHeader
headerType HttpExpect = RequestHeader
headerType HttpFrom = RequestHeader
headerType HttpHost = RequestHeader
headerType HttpIfMatch = RequestHeader
headerType HttpIfModifiedSince = RequestHeader
headerType HttpIfNoneMatch = RequestHeader
headerType HttpIfRange = RequestHeader
headerType HttpIfUnmodifiedSince = RequestHeader
headerType HttpMaxForwards = RequestHeader
headerType HttpProxyAuthorization = RequestHeader
headerType HttpRange = RequestHeader
headerType HttpReferer = RequestHeader
headerType HttpTE = RequestHeader
headerType HttpUserAgent = RequestHeader
headerType HttpAcceptRanges = ResponseHeader
headerType HttpAge = ResponseHeader
headerType HttpETag = ResponseHeader
headerType HttpLocation = ResponseHeader
headerType HttpProxyAuthenticate = ResponseHeader
headerType HttpRetryAfter = ResponseHeader
headerType HttpServer = ResponseHeader
headerType HttpVary = ResponseHeader
headerType HttpWWWAuthenticate = ResponseHeader
headerType HttpAllow = EntityHeader
headerType HttpContentEncoding = EntityHeader
headerType HttpContentLanguage = EntityHeader
headerType HttpContentLength = EntityHeader
headerType HttpContentLocation = EntityHeader
headerType HttpContentMD5 = EntityHeader
headerType HttpContentRange = EntityHeader
headerType HttpContentType = EntityHeader
headerType HttpExpires = EntityHeader
headerType HttpLastModified = EntityHeader
headerType (HttpExtensionHeader _) = EntityHeader
headerType HttpConnection = RequestHeader
headerType HttpCookie = RequestHeader
headerType HttpSetCookie = ResponseHeader


requestVariableNameIsHeader :: String -> Bool
requestVariableNameIsHeader name = (length name > 5) && (take 5 name == "HTTP_")


requestVariableNameToHeaderName :: String -> Maybe String
requestVariableNameToHeaderName name
    = if requestVariableNameIsHeader name
        then let split [] = []
                 split string = case elemIndex '_' string of
                                  Nothing -> [string]
                                  Just index ->
                                    let (first, rest) = splitAt index string
                                    in first : (split $ drop 1 rest)
                 titleCase word = [toUpper $ head word] ++ (map toLower $ tail word)
                 headerName = intercalate "-" $ map titleCase $ split $ drop 5 name
             in Just headerName
        else Nothing


requestVariableNameToHeader :: String -> Maybe Header
requestVariableNameToHeader "HTTP_ACCEPT" = Just HttpAccept
requestVariableNameToHeader "HTTP_ACCEPT_CHARSET" = Just HttpAcceptCharset
requestVariableNameToHeader "HTTP_ACCEPT_ENCODING" = Just HttpAcceptEncoding
requestVariableNameToHeader "HTTP_ACCEPT_LANGUAGE" = Just HttpAcceptLanguage
requestVariableNameToHeader "HTTP_AUTHORIZATION" = Just HttpAuthorization
requestVariableNameToHeader "HTTP_EXPECT" = Just HttpExpect
requestVariableNameToHeader "HTTP_FROM" = Just HttpFrom
requestVariableNameToHeader "HTTP_HOST" = Just HttpHost
requestVariableNameToHeader "HTTP_IF_MATCH" = Just HttpIfMatch
requestVariableNameToHeader "HTTP_IF_MODIFIED_SINCE" = Just HttpIfModifiedSince
requestVariableNameToHeader "HTTP_IF_NONE_MATCH" = Just HttpIfNoneMatch
requestVariableNameToHeader "HTTP_IF_RANGE" = Just HttpIfRange
requestVariableNameToHeader "HTTP_IF_UNMODIFIED_SINCE" = Just HttpIfUnmodifiedSince
requestVariableNameToHeader "HTTP_MAX_FORWARDS" = Just HttpMaxForwards
requestVariableNameToHeader "HTTP_PROXY_AUTHORIZATION" = Just HttpProxyAuthorization
requestVariableNameToHeader "HTTP_RANGE" = Just HttpRange
requestVariableNameToHeader "HTTP_REFERER" = Just HttpReferer
requestVariableNameToHeader "HTTP_TE" = Just HttpTE
requestVariableNameToHeader "HTTP_USER_AGENT" = Just HttpUserAgent
requestVariableNameToHeader "HTTP_ALLOW" = Just HttpAllow
requestVariableNameToHeader "HTTP_CONTENT_ENCODING" = Just HttpContentEncoding
requestVariableNameToHeader "HTTP_CONTENT_LANGUAGE" = Just HttpContentLanguage
requestVariableNameToHeader "HTTP_CONTENT_LENGTH" = Just HttpContentLength
requestVariableNameToHeader "HTTP_CONTENT_LOCATION" = Just HttpContentLocation
requestVariableNameToHeader "HTTP_CONTENT_MD5" = Just HttpContentMD5
requestVariableNameToHeader "HTTP_CONTENT_RANGE" = Just HttpContentRange
requestVariableNameToHeader "HTTP_CONTENT_TYPE" = Just HttpContentType
requestVariableNameToHeader "HTTP_EXPIRES" = Just HttpExpires
requestVariableNameToHeader "HTTP_LAST_MODIFIED" = Just HttpLastModified
requestVariableNameToHeader "HTTP_CONNECTION" = Just HttpConnection
requestVariableNameToHeader "HTTP_COOKIE" = Just HttpCookie
requestVariableNameToHeader name
    = if requestVariableNameIsHeader name
        then Just $ HttpExtensionHeader $ fromJust $ requestVariableNameToHeaderName name
        else Nothing


isValidInRequest :: Header -> Bool
isValidInRequest header = (headerType header == RequestHeader)
                          || (headerType header == EntityHeader)


isValidInResponse :: Header -> Bool
isValidInResponse header = (headerType header == ResponseHeader)
                           || (headerType header == EntityHeader)
