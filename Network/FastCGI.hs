{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, DeriveDataTypeable #-}
module Network.FastCGI (
             -- * The monad
             FastCGI,
             FastCGIState,
             MonadFastCGI,
             getFastCGIState,
             implementationThrowFastCGI,
             implementationCatchFastCGI,
             implementationBlockFastCGI,
             implementationUnblockFastCGI,
             
             -- * Accepting requests
             acceptLoop,
             
             -- * Logging
             fLog,
             
             -- * Request information
             -- | It is common practice for web servers to make their own extensions to
             --   the CGI/1.1 set of defined variables.  For example, @REMOTE_PORT@ is
             --   not defined by the specification, but often seen in the wild.
             --   Furthermore, it is also common for user agents to make their own
             --   extensions to the HTTP/1.1 set of defined headers.  Therefore, there
             --   are two levels of call available.  Defined variables and headers may
             --   be interrogated directly, and in addition, there are higher-level
             --   calls which give convenient names and types to the same information.
             --   
             --   Cookies may also be manipulated through HTTP headers directly; the
             --   functions here are provided only as a convenience.
             getRequestVariable,
             getAllRequestVariables,
             Header(..),
             getRequestHeader,
             getAllRequestHeaders,
             Cookie(..),
             getCookie,
             getAllCookies,
             getCookieValue,
             getDocumentRoot,
             getGatewayInterface,
             getPathInfo,
             getPathTranslated,
             getQueryString,
             getRedirectStatus,
             getRedirectURI,
             getRemoteAddress,
             getRemotePort,
             getRemoteHost,
             getRemoteIdent,
             getRemoteUser,
             getRequestMethod,
             getRequestURI,
             getScriptFilename,
             getScriptName,
             getServerAddress,
             getServerName,
             getServerPort,
             getServerProtocol,
             getServerSoftware,
             getAuthenticationType,
             getContentLength,
             getContentType,
             
             -- * Request content data
             -- | At the moment the handler is invoked, all request headers have been
             --   received, but content data has not necessarily been.  Requests to read
             --   content data block the handler (but not other concurrent handlers)
             --   until there is enough data in the buffer to satisfy them, or until
             --   timeout where applicable.
             fGet,
             fGetNonBlocking,
             fGetContents,
             fIsReadable,
             
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
             --   
             --   Cookies may also be manipulated through HTTP headers directly; the
             --   functions here are provided only as a convenience.
             setResponseStatus,
             getResponseStatus,
             setResponseHeader,
             unsetResponseHeader,
             getResponseHeader,
             setCookie,
             unsetCookie,
             mkSimpleCookie,
             mkCookie,
             permanentRedirect,
             seeOtherRedirect,
             sendResponseHeaders,
             responseHeadersSent,
             fPut,
             fPutStr,
             fCloseOutput,
             fIsWritable,
             
             -- * Exceptions
             --   Because it is not possible for user code to enter the FastCGI monad
             --   from outside it, catching exceptions in IO will not work.  Therefore
             --   a full set of exception primitives designed to work with any
             --   'MonadFastCGI' instance is provided.
             FastCGIException(..),
             fThrow,
             fCatch,
             fBlock,
             fUnblock,
             fBracket,
             fFinally,
             fTry,
             fHandle,
             fOnException
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
import Data.Typeable
import Data.Word
import Foreign.C.Error
import GHC.IO.Exception (IOErrorType(..))
import qualified Network.Socket as Network hiding (send, sendTo, recv, recvFrom)
import qualified Network.Socket.ByteString as Network
import Prelude hiding (catch)
import System.Environment
import System.IO.Error (ioeGetErrorType)
import qualified System.IO.Error as System


-- | An opaque type representing the state of a single connection from the web server.
data FastCGIState = FastCGIState {
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
      stdinStreamBufferMVar :: MVar BS.ByteString,
      stdinStreamClosedMVar :: MVar Bool,
      requestEndedMVar :: MVar Bool,
      requestVariableMapMVar :: MVar (Map.Map String String),
      requestHeaderMapMVar :: MVar (Map.Map Header String),
      requestCookieMapMVar :: MVar (Map.Map String Cookie),
      responseStatusMVar :: MVar Int,
      responseHeaderMapMVar :: MVar (Map.Map Header String),
      responseHeadersSentMVar :: MVar Bool,
      responseCookieMapMVar :: MVar (Map.Map String Cookie)
    }


data Cookie = Cookie {
      cookieName :: String,
      cookieValue :: String,
      cookieVersion :: Int,
      cookiePath :: Maybe String,
      cookieDomain :: Maybe String,
      cookieMaxAge :: Maybe Int,
      cookieSecure :: Bool,
      cookieComment :: Maybe String
    } deriving (Show)


-- | The monad within which each single connection from the web server is handled.
type FastCGI = ReaderT FastCGIState IO


-- | The class of monads within which the FastCGI calls are valid.  You may wish to
--   create your own monad implementing this class.
class (MonadIO m) => MonadFastCGI m where
    -- | Returns the opaque 'FastCGIState' object representing the state of the
    --   FastCGI client.
    --   Should not be called directly by user code, except implementations of
    --   'MonadFastCGI'; exported so that
    --   user monads can implement the interface.
    getFastCGIState
        :: m FastCGIState
    -- | Throws an exception in the monad.
    --   Should not be called directly by user code; exported so that
    --   user monads can implement the interface.  See 'fThrow'.
    implementationThrowFastCGI
        :: (Exception.Exception e)
        => e -- ^ The exception to throw
        -> m a
    -- | Perform an action in the monad, with a given exception-handler action bound.
    --   Should not be called directly by user code; exported so that
    --   user monads can implement the interface.  See 'fCatch'.
    implementationCatchFastCGI
        :: (Exception.Exception e)
        => m a -- ^ The action to run with the exception handler binding in scope.
        -> (e -> m a) -- ^ The exception handler to bind.
        -> m a
    -- | Block exceptions within an action.
    --   Should not be called directly by user code; exported so that
    --   user monads can implement the interface.  See 'fBlock'.
    implementationBlockFastCGI
        :: m a -- ^ The action to run with exceptions blocked.
        -> m a
    -- | Unblock exceptions within an action.
    --   Should not be called directly by user code; exported so that
    --   user monads can implement the interface.  See 'fUnblock'.
    implementationUnblockFastCGI
        :: m a -- ^ The action to run with exceptions unblocked.
        -> m a


instance MonadFastCGI FastCGI where
    getFastCGIState = ask
    implementationThrowFastCGI exception = liftIO $ Exception.throwIO exception
    implementationCatchFastCGI action handler = do
      state <- getFastCGIState
      liftIO $ Exception.catch (runReaderT action state)
                               (\exception -> do
                                  runReaderT (handler exception) state)
    implementationBlockFastCGI action = do
      state <- getFastCGIState
      liftIO $ Exception.block (runReaderT action state)
    implementationUnblockFastCGI action = do
      state <- getFastCGIState
      liftIO $ Exception.unblock (runReaderT action state)


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
--   your own monad within IO.  You simply have to implement the 'MonadFastCGI' class.
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
  maybeListenSocket <- createListenSocket
  webServerAddresses <- computeWebServerAddresses
  case maybeListenSocket of
    Nothing -> return ()
    Just listenSocket -> do
      let acceptLoop' = do
            (socket, peer) <- Network.accept listenSocket
            requestChannelMapMVar <- newMVar $ Map.empty
            let state = FastCGIState {
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
                  fLog $ "Ignoring connection from invalid address: "
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


validateWebServerAddress :: (MonadFastCGI m) => m Bool
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
          stdinStreamBufferMVar <- liftIO $ newMVar $ BS.empty
          stdinStreamClosedMVar <- liftIO $ newMVar $ False
          requestEndedMVar <- liftIO $ newMVar $ False
          requestVariableMapMVar <- liftIO $ newMVar $ Map.empty
          requestHeaderMapMVar <- liftIO $ newMVar $ Map.empty
          requestCookieMapMVar <- liftIO $ newMVar $ Map.empty
          responseStatusMVar <- liftIO $ newMVar $ 200
          responseHeaderMapMVar
              <- liftIO $ newMVar $ Map.fromList [(HttpContentType, "text/html")]
          responseHeadersSentMVar <- liftIO $ newMVar $ False
          responseCookieMapMVar <- liftIO $ newMVar $ Map.empty
          let requestChannelMap' = Map.insert (recordRequestID record)
                                              requestChannel
                                              requestChannelMap
              request = Request {
                                requestID = recordRequestID record,
                                requestChannel = requestChannel,
                                paramsStreamBufferMVar = paramsStreamBufferMVar,
                                stdinStreamBufferMVar = stdinStreamBufferMVar,
                                stdinStreamClosedMVar = stdinStreamClosedMVar,
                                requestEndedMVar = requestEndedMVar,
                                requestVariableMapMVar = requestVariableMapMVar,
                                requestHeaderMapMVar = requestHeaderMapMVar,
                                requestCookieMapMVar = requestCookieMapMVar,
                                responseStatusMVar = responseStatusMVar,
                                responseHeaderMapMVar = responseHeaderMapMVar,
                                responseHeadersSentMVar = responseHeadersSentMVar,
                                responseCookieMapMVar = responseCookieMapMVar
                              }
              state' = state { request = Just request }
          liftIO $ putMVar (requestChannelMapMVar state) requestChannelMap'
          liftIO $ fork $ do
            Exception.catch (runReaderT (insideRequestLoop handler) state')
                            (\error -> flip runReaderT state' $ do
                               fLog $ "Uncaught exception: "
                                      ++ (show (error :: Exception.SomeException))
                               fCloseOutput)
          return ()
        OtherRecord unknownCode -> do
          sendRecord $ Record {
                               recordType = UnknownTypeRecord,
                               recordRequestID = 0,
                               recordContent = BS.pack [fromIntegral unknownCode,
                                                        0, 0, 0, 0, 0, 0, 0]
                             }
        GetValuesRecord -> do
          fLog $ "Get values record: " ++ (show record)
        _ -> do
          state <- getFastCGIState
          requestChannelMap <- liftIO $ readMVar $ requestChannelMapMVar state
          let requestID = recordRequestID record
              maybeRequestChannel = Map.lookup requestID requestChannelMap
          case maybeRequestChannel of
            Nothing ->
                fLog $ "Ignoring record for unknown request ID " ++ (show requestID)
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
          sendResponseHeaders
          requestEnded <- liftIO $ readMVar $ requestEndedMVar request
          if not requestEnded
            then terminateRequest
            else return ()
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
          insideRequestLoop handler
    _ -> do
      fLog $ "Ignoring record of unexpected type "
             ++ (show $ recordType record)


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
                                             cookieDomain = maybeDomain,
                                             cookieMaxAge = Nothing,
                                             cookieSecure = False,
                                             cookieComment = Nothing
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


printCookies :: [Cookie] -> String
printCookies cookies =
    let printCookie cookie
            = intercalate ";" $ map printNameValuePair $ nameValuePairs cookie
        printNameValuePair (name, Nothing) = name
        printNameValuePair (name, Just value)
            = name ++ "=" ++ value
        {- Safari doesn't like this.
            = if isValidCookieToken value
                then name ++ "=" ++ value
                else name ++ "=\"" ++ escape value ++ "\""
         -}
        escape "" = ""
        escape ('\\':rest) = "\\\\" ++ escape rest
        escape ('\"':rest) = "\\\"" ++ escape rest
        escape (c:rest) = [c] ++ escape rest
        nameValuePairs cookie = [(cookieName cookie, Just $ cookieValue cookie)]
                                ++ (case cookieComment cookie of
                                      Nothing -> []
                                      Just comment -> [("Comment", Just comment)])
                                ++ (case cookieDomain cookie of
                                      Nothing -> []
                                      Just domain -> [("Domain", Just domain)])
                                ++ (case cookieMaxAge cookie of
                                      Nothing -> []
                                      Just maxAge -> [("Max-Age", Just $ show maxAge)])
                                ++ (case cookiePath cookie of
                                      Nothing -> []
                                      Just path -> [("Path", Just $ path)])
                                ++ (case cookieSecure cookie of
                                      False -> []
                                      True -> [("Secure", Nothing)])
                                ++ [("Version", Just $ show $ cookieVersion cookie)]
    in intercalate "," $ map printCookie cookies


parseInt :: String -> Maybe Int
parseInt string =
    if (length string > 0) && (all isDigit string)
      then Just $ let accumulate "" accumulator = accumulator
                      accumulate (n:rest) accumulator
                                 = accumulate rest $ accumulator * 10 + digitToInt n
                  in accumulate string 0
      else Nothing


recvRecord :: (MonadFastCGI m) => m (Maybe Record)
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
          fLog $ "Record header of unrecognized version: "
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


sendRecord :: (MonadFastCGI m) => Record -> m ()
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
fLog :: (MonadFastCGI m) => String -> m ()
fLog message = do
  FastCGIState { request = maybeRequest } <- getFastCGIState
  case maybeRequest of
    Nothing -> do
      -- As you can see, the description is actually incomplete.  If there's no request
      -- in progress, we use syslog instead.  But since the user can never call us
      -- outside a request, that would only be confusing if documented.
      -- liftIO $ withSyslog "direct-fastcgi" [PID] USER $ syslog Error message
      return ()
    Just request -> do
      if length message > 0
        then sendRecord $ Record {
                      recordType = StderrRecord,
                      recordRequestID = requestID request,
                      recordContent = BS.fromString message
                    }
        else return ()


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
      deriving (Eq, Ord)


instance Show Header where 
    show header = fromHeader header


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


fromHeader :: Header -> String
fromHeader HttpAccept = "Accept"
fromHeader HttpAcceptCharset = "Accept-Charset"
fromHeader HttpAcceptEncoding = "Accept-Encoding"
fromHeader HttpAcceptLanguage = "Accept-Language"
fromHeader HttpAuthorization = "Authorization"
fromHeader HttpExpect = "Expect"
fromHeader HttpFrom = "From"
fromHeader HttpHost = "Host"
fromHeader HttpIfMatch = "If-Match"
fromHeader HttpIfModifiedSince = "If-Modified-Since"
fromHeader HttpIfNoneMatch = "If-None-Match"
fromHeader HttpIfRange = "If-Range"
fromHeader HttpIfUnmodifiedSince = "If-Unmodified-Since"
fromHeader HttpMaxForwards = "Max-Forwards"
fromHeader HttpProxyAuthorization = "Proxy-Authorization"
fromHeader HttpRange = "Range"
fromHeader HttpReferer = "Referer"
fromHeader HttpTE = "TE"
fromHeader HttpUserAgent = "User-Agent"
fromHeader HttpAcceptRanges = "Accept-Ranges"
fromHeader HttpAge = "Age"
fromHeader HttpETag = "ETag"
fromHeader HttpLocation = "Location"
fromHeader HttpProxyAuthenticate = "Proxy-Authenticate"
fromHeader HttpRetryAfter = "Retry-After"
fromHeader HttpServer = "Server"
fromHeader HttpVary = "Vary"
fromHeader HttpWWWAuthenticate = "WWW-Authenticate"
fromHeader HttpAllow = "Allow"
fromHeader HttpContentEncoding = "Content-Encoding"
fromHeader HttpContentLanguage = "Content-Language"
fromHeader HttpContentLength = "Content-Length"
fromHeader HttpContentLocation = "Content-Location"
fromHeader HttpContentMD5 = "Content-MD5"
fromHeader HttpContentRange = "Content-Range"
fromHeader HttpContentType = "Content-Type"
fromHeader HttpExpires = "Expires"
fromHeader HttpLastModified = "Last-Modified"
fromHeader (HttpExtensionHeader name) = name
fromHeader HttpConnection = "Connection"
fromHeader HttpCookie = "Cookie"
fromHeader HttpSetCookie = "Set-Cookie"


toHeader :: String -> Header
toHeader "Accept" = HttpAccept
toHeader "Accept-Charset" = HttpAcceptCharset
toHeader "Accept-Encoding" = HttpAcceptEncoding
toHeader "Accept-Language" = HttpAcceptLanguage
toHeader "Authorization" = HttpAuthorization
toHeader "Expect" = HttpExpect
toHeader "From" = HttpFrom
toHeader "Host" = HttpHost
toHeader "If-Match" = HttpIfMatch
toHeader "If-Modified-Since" = HttpIfModifiedSince
toHeader "If-None-Match" = HttpIfNoneMatch
toHeader "If-Range" = HttpIfRange
toHeader "If-Unmodified-Since" = HttpIfUnmodifiedSince
toHeader "Max-Forwards" = HttpMaxForwards
toHeader "Proxy-Authorization" = HttpProxyAuthorization
toHeader "Range" = HttpRange
toHeader "Referer" = HttpReferer
toHeader "TE" = HttpTE
toHeader "User-Agent" = HttpUserAgent
toHeader "Accept-Ranges" = HttpAcceptRanges
toHeader "Age" = HttpAge
toHeader "ETag" = HttpETag
toHeader "Location" = HttpLocation
toHeader "Proxy-Authenticate" = HttpProxyAuthenticate
toHeader "Retry-After" = HttpRetryAfter
toHeader "Server" = HttpServer
toHeader "Vary" = HttpVary
toHeader "WWW-Authenticate" = HttpWWWAuthenticate
toHeader "Allow" = HttpAllow
toHeader "Content-Encoding" = HttpContentEncoding
toHeader "Content-Language" = HttpContentLanguage
toHeader "Content-Length" = HttpContentLength
toHeader "Content-Location" = HttpContentLocation
toHeader "Content-MD5" = HttpContentMD5
toHeader "Content-Range" = HttpContentRange
toHeader "Content-Type" = HttpContentType
toHeader "Expires" = HttpExpires
toHeader "Last-Modified" = HttpLastModified
toHeader "Connection" = HttpConnection
toHeader "Cookie" = HttpCookie
toHeader "Set-Cookie" = HttpSetCookie
toHeader name = HttpExtensionHeader name


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


isValidInResponse :: Header -> Bool
isValidInResponse header = (headerType header == ResponseHeader)
                           || (headerType header == EntityHeader)


-- | Queries the value from the web server of the CGI/1.1 request variable with the
--   given name for this request.
getRequestVariable
    :: (MonadFastCGI m)
    => String -- ^ The name of the request variable to query.
    -> m (Maybe String) -- ^ The value of the request variable, if the web server
                        --   provided one.
getRequestVariable name = do
  state <- getFastCGIState
  requestVariableMap
      <- liftIO $ readMVar $ requestVariableMapMVar $ fromJust $ request state
  return $ Map.lookup name requestVariableMap


-- | Returns an association list of name-value pairs of all the CGI/1.1 request
--   variables from the web server.
getAllRequestVariables
    :: (MonadFastCGI m) => m [(String, String)]
getAllRequestVariables = do
  state <- getFastCGIState
  requestVariableMap
      <- liftIO $ readMVar $ requestVariableMapMVar $ fromJust $ request state
  return $ Map.assocs requestVariableMap


-- | Queries the value from the user agent of the given HTTP/1.1 header.
getRequestHeader
    :: (MonadFastCGI m)
    => Header -- ^ The header to query.  Must be a request or entity header.
    -> m (Maybe String) -- ^ The value of the header, if the user agent provided one.
getRequestHeader header = do
  state <- getFastCGIState
  requestHeaderMap
      <- liftIO $ readMVar $ requestHeaderMapMVar $ fromJust $ request state
  return $ Map.lookup header requestHeaderMap


-- | Returns an association list of name-value pairs of all the HTTP/1.1 request or
--   entity headers from the user agent.
getAllRequestHeaders :: (MonadFastCGI m) => m [(Header, String)]
getAllRequestHeaders = do
  state <- getFastCGIState
  requestHeaderMap
      <- liftIO $ readMVar $ requestHeaderMapMVar $ fromJust $ request state
  return $ Map.assocs requestHeaderMap


-- | Returns a 'Cookie' object for the given name, if the user agent provided one
--   in accordance with RFC 2109.
getCookie
    :: (MonadFastCGI m)
    => String -- ^ The name of the cookie to look for.
    -> m (Maybe Cookie) -- ^ The cookie, if the user agent provided it.
getCookie name = do
  state <- getFastCGIState
  requestCookieMap
      <- liftIO $ readMVar $ requestCookieMapMVar $ fromJust $ request state
  return $ Map.lookup name requestCookieMap


-- | Returns all 'Cookie' objects provided by the user agent in accordance 
--   RFC 2109.
getAllCookies :: (MonadFastCGI m) => m [Cookie]
getAllCookies = do
  state <- getFastCGIState
  requestCookieMap
      <- liftIO $ readMVar $ requestCookieMapMVar $ fromJust $ request state
  return $ Map.elems requestCookieMap


-- | A convenience method; as 'getCookie', but returns only the value of the cookie
--   rather than a 'Cookie' object.
getCookieValue
    :: (MonadFastCGI m)
    => String -- ^ The name of the cookie to look for.
    -> m (Maybe String) -- ^ The value of the cookie, if the user agent provided it.
getCookieValue name = do
  state <- getFastCGIState
  requestCookieMap
      <- liftIO $ readMVar $ requestCookieMapMVar $ fromJust $ request state
  return $ case Map.lookup name requestCookieMap of
    Nothing -> Nothing
    Just cookie -> Just $ cookieValue cookie


-- | Return the document root, as provided by the web server, if it was provided.
getDocumentRoot :: (MonadFastCGI m) => m (Maybe String)
getDocumentRoot = do
  getRequestVariable "DOCUMENT_ROOT"


-- | Return the gateway interface, as provided by the web server, if it was provided.
getGatewayInterface :: (MonadFastCGI m) => m (Maybe String)
getGatewayInterface = do
  getRequestVariable "GATEWAY_INTERFACE"


-- | Return the path info, as provided by the web server, if it was provided.
getPathInfo :: (MonadFastCGI m) => m (Maybe String)
getPathInfo = do
  getRequestVariable "PATH_INFO"


-- | Return the path-translated value, as provided by the web server, if it was provided.
getPathTranslated :: (MonadFastCGI m) => m (Maybe String)
getPathTranslated = do
  getRequestVariable "PATH_TRANSLATED"


-- | Return the query string, as provided by the web server, if it was provided.
getQueryString :: (MonadFastCGI m) => m (Maybe String)
getQueryString = do
  getRequestVariable "QUERY_STRING"


-- | Return the redirect status, as provided by the web server, if it was provided.
getRedirectStatus :: (MonadFastCGI m) => m (Maybe Int)
getRedirectStatus = do
  value <- getRequestVariable "REDIRECT_STATUS"
  return $ case value of
    Nothing -> Nothing
    Just value -> parseInt value


-- | Return the redirect URI, as provided by the web server, if it was provided.
getRedirectURI :: (MonadFastCGI m) => m (Maybe String)
getRedirectURI = do
  getRequestVariable "REDIRECT_URI"


-- | Return the remote address, as provided by the web server, if it was provided.
getRemoteAddress :: (MonadFastCGI m) => m (Maybe Network.HostAddress)
getRemoteAddress = do
  value <- getRequestVariable "REMOTE_ADDR"
  case value of
    Nothing -> return Nothing
    Just value -> do
      fCatch (do
               value' <- liftIO $ Network.inet_addr value
               return $ Just value')
             (\exception -> do
                return (exception :: System.IOError)
                return Nothing)


-- | Return the remote port, as provided by the web server, if it was provided.
getRemotePort :: (MonadFastCGI m) => m (Maybe Int)
getRemotePort = do
  value <- getRequestVariable "REMOTE_PORT"
  return $ case value of
    Nothing -> Nothing
    Just value -> parseInt value


-- | Return the remote hostname, as provided by the web server, if it was provided.
getRemoteHost :: (MonadFastCGI m) => m (Maybe String)
getRemoteHost = do
  getRequestVariable "REMOTE_HOST"


-- | Return the remote ident value, as provided by the web server, if it was provided.
getRemoteIdent :: (MonadFastCGI m) => m (Maybe String)
getRemoteIdent = do
  getRequestVariable "REMOTE_IDENT"


-- | Return the remote user name, as provided by the web server, if it was provided.
getRemoteUser :: (MonadFastCGI m) => m (Maybe String)
getRemoteUser = do
  getRequestVariable "REMOTE_USER"


-- | Return the request method, as provided by the web server, if it was provided.
getRequestMethod :: (MonadFastCGI m) => m (Maybe String)
getRequestMethod = do
  getRequestVariable "REQUEST_METHOD"


-- | Return the request URI, as provided by the web server, if it was provided.
getRequestURI :: (MonadFastCGI m) => m (Maybe String)
getRequestURI = do
  getRequestVariable "REQUEST_URI"


-- | Return the script filename, as provided by the web server, if it was provided.
getScriptFilename :: (MonadFastCGI m) => m (Maybe String)
getScriptFilename = do
  getRequestVariable "SCRIPT_FILENAME"


-- | Return the script name, as provided by the web server, if it was provided.
getScriptName :: (MonadFastCGI m) => m (Maybe String)
getScriptName = do
  getRequestVariable "SCRIPT_NAME"


-- | Return the server address, as provided by the web server, if it was provided.
getServerAddress :: (MonadFastCGI m) => m (Maybe Network.HostAddress)
getServerAddress = do
  value <- getRequestVariable "SERVER_ADDR"
  case value of
    Nothing -> return Nothing
    Just value -> do
      fCatch (do
               value' <- liftIO $ Network.inet_addr value
               return $ Just value')
             (\exception -> do
                return (exception :: System.IOError)
                return Nothing)


-- | Return the server name, as provided by the web server, if it was provided.
getServerName :: (MonadFastCGI m) => m (Maybe String)
getServerName = do
  getRequestVariable "SERVER_NAME"


-- | Return the server port, as provided by the web server, if it was provided.
getServerPort :: (MonadFastCGI m) => m (Maybe Int)
getServerPort = do
  value <- getRequestVariable "SERVER_PORT"
  return $ case value of
    Nothing -> Nothing
    Just value -> parseInt value


-- | Return the server protocol, as provided by the web server, if it was provided.
getServerProtocol :: (MonadFastCGI m) => m (Maybe String)
getServerProtocol = do
  getRequestVariable "SERVER_PROTOCOL"


-- | Return the server software name and version, as provided by the web server, if
--   it was provided.
getServerSoftware :: (MonadFastCGI m) => m (Maybe String)
getServerSoftware = do
  getRequestVariable "SERVER_SOFTWARE"


-- | Return the authentication type, as provided by the web server, if it was provided.
getAuthenticationType :: (MonadFastCGI m) => m (Maybe String)
getAuthenticationType = do
  getRequestVariable "AUTH_TYPE"


-- | Return the content length, as provided by the web server, if it was provided.
getContentLength :: (MonadFastCGI m) => m (Maybe Int)
getContentLength = do
  value <- getRequestVariable "CONTENT_LENGTH"
  return $ case value of
    Nothing -> Nothing
    Just value -> parseInt value


-- | Return the content type, as provided by the web server, if it was provided.
getContentType :: (MonadFastCGI m) => m (Maybe String)
getContentType = do
  getRequestVariable "CONTENT_TYPE"


-- | Reads up to a specified amount of data from the input stream of the current request,
--   and interprets it as binary data.  This is the content data of the HTTP request,
--   if any.  If input has been closed, returns an empty bytestring.  If insufficient
--   input is available, blocks until there is enough.  If output has been closed,
--   causes an 'OutputAlreadyClosed' exception.
fGet :: (MonadFastCGI m) => Int -> m BS.ByteString
fGet size = fGet' size False


-- | Reads up to a specified amount of data from the input stream of the curent request,
--   and interprets it as binary data.  This is the content data of the HTTP request,
--   if any.  If input has been closed, returns an empty bytestring.  If insufficient
--   input is available, returns any input which is immediately available, or an empty
--   bytestring if there is none, never blocking.  If output has been closed, causes an
--   'OutputAlreadyClosed' exception.
fGetNonBlocking :: (MonadFastCGI m) => Int -> m BS.ByteString
fGetNonBlocking size = fGet' size True


fGet' :: (MonadFastCGI m) => Int -> Bool -> m BS.ByteString
fGet' size nonBlocking = do
  requireOutputNotYetClosed
  FastCGIState { request = Just request } <- getFastCGIState
  extendStdinStreamBufferToLength size nonBlocking
  stdinStreamBuffer <- liftIO $ takeMVar $ stdinStreamBufferMVar request
  if size <= BS.length stdinStreamBuffer
    then do
      let result = BS.take size stdinStreamBuffer
          remainder = BS.drop size stdinStreamBuffer
      liftIO $ putMVar (stdinStreamBufferMVar request) remainder
      return result
    else do
      liftIO $ putMVar (stdinStreamBufferMVar request) BS.empty
      return stdinStreamBuffer


-- | Reads all remaining data from the input stream of the current request, and
--   interprets it as binary data.  This is the content data of the HTTP request, if
--   any.  Blocks until all input has been read.  If input has been closed, returns an
--   empty bytestring.  If output has been closed, causes an 'OutputAlreadyClosed'
--   exception.
fGetContents :: (MonadFastCGI m) => m BS.ByteString
fGetContents = do
  requireOutputNotYetClosed
  FastCGIState { request = Just request } <- getFastCGIState
  let extend = do
        stdinStreamBuffer <- liftIO $ readMVar $ stdinStreamBufferMVar request
        extendStdinStreamBufferToLength (BS.length stdinStreamBuffer + 1) False
        stdinStreamClosed <- liftIO $ readMVar $ stdinStreamClosedMVar request
        if stdinStreamClosed
          then do
            stdinStreamBuffer
                <- liftIO $ swapMVar (stdinStreamBufferMVar request) BS.empty
            return stdinStreamBuffer
          else extend
  extend


-- | Returns whether the input stream of the current request potentially has data
--   remaining, either in the buffer or yet to be read.  This is the content data of
--   the HTTP request, if any.
fIsReadable :: (MonadFastCGI m) => m Bool
fIsReadable = do
  FastCGIState { request = Just request } <- getFastCGIState
  stdinStreamBuffer <- liftIO $ readMVar $ stdinStreamBufferMVar request
  if BS.length stdinStreamBuffer > 0
    then return True
    else do
      stdinStreamClosed <- liftIO $ readMVar $ stdinStreamClosedMVar request
      requestEnded <- liftIO $ readMVar $ requestEndedMVar request
      return $ (not stdinStreamClosed) && (not requestEnded)


extendStdinStreamBufferToLength :: (MonadFastCGI m) => Int -> Bool -> m ()
extendStdinStreamBufferToLength desiredLength nonBlocking = do
  FastCGIState { request = Just request } <- getFastCGIState
  stdinStreamBuffer <- liftIO $ takeMVar $ stdinStreamBufferMVar request
  let extend bufferSoFar = do
        if BS.length bufferSoFar >= desiredLength
          then liftIO $ putMVar (stdinStreamBufferMVar request) bufferSoFar
          else do
            maybeRecord <- if nonBlocking
                             then do
                               isEmpty <- liftIO $ isEmptyChan $ requestChannel request
                               if isEmpty
                                 then return Nothing
                                 else do
                                   record <- liftIO $ readChan $ requestChannel request
                                   return $ Just record
                             else do
                               record <- liftIO $ readChan $ requestChannel request
                               return $ Just record
            case maybeRecord of
              Nothing -> liftIO $ putMVar (stdinStreamBufferMVar request) bufferSoFar
              Just record
                -> case recordType record of
                     StdinRecord -> do
                       case BS.length $ recordContent record of
                         0 -> do
                           liftIO $ swapMVar (stdinStreamClosedMVar request) True
                           liftIO $ putMVar (stdinStreamBufferMVar request) bufferSoFar
                         _ -> do
                           extend $ BS.append bufferSoFar $ recordContent record
                     _ -> do
                       fLog $ "Ignoring record of unexpected type "
                              ++ (show $ recordType record)
  extend stdinStreamBuffer


-- | Sets the response status which will be sent with the response headers.  If the
--   response headers have already been sent, causes a 'ResponseHeadersAlreadySent'
--   exception.
setResponseStatus
    :: (MonadFastCGI m)
    => Int -- ^ The HTTP/1.1 status code to set.
    -> m ()
setResponseStatus status = do
  requireResponseHeadersNotYetSent
  FastCGIState { request = Just request } <- getFastCGIState
  liftIO $ swapMVar (responseStatusMVar request) status
  return ()
      


-- | Returns the response status which will be or has been sent with the response
--   headers.
getResponseStatus
    :: (MonadFastCGI m)
    => m Int -- ^ The HTTP/1.1 status code.
getResponseStatus = do
  FastCGIState { request = Just request } <- getFastCGIState
  liftIO $ readMVar (responseStatusMVar request)


-- | Sets the given 'HttpHeader' response header to the given string value, overriding
--   any value which has previously been set.  If the response headers have already
--   been sent, causes a 'ResponseHeadersAlreadySent' exception.  If the header is not
--   an HTTP/1.1 or extension response or entity header, ie, is not valid as part of
--   a response, causes a 'NotAResponseHeader' exception.
--   
--   If a value is set for the 'HttpSetCookie' header, this overrides all cookies set
--   for this request with 'setCookie'.
setResponseHeader
    :: (MonadFastCGI m)
    => Header -- ^ The header to set.  Must be a response header or an entity header.
    -> String -- ^ The value to set.
    -> m ()
setResponseHeader header value = do
  requireResponseHeadersNotYetSent
  if isValidInResponse header
    then do
      FastCGIState { request = Just request } <- getFastCGIState
      responseHeaderMap <- liftIO $ takeMVar $ responseHeaderMapMVar request
      let responseHeaderMap' = Map.insert header value responseHeaderMap
      liftIO $ putMVar (responseHeaderMapMVar request) responseHeaderMap'
    else fThrow $ NotAResponseHeader header


-- | Causes the given 'HttpHeader' response header not to be sent, overriding any value
--   which has previously been set.  If the response headers have already been sent,
--   causes a 'ResponseHeadersAlreadySent' exception.  If the header is not an HTTP/1.1
--   or extension response or entity header, ie, is not valid as part of a response,
--   causes a 'NotAResponseHeader' exception.
--   
--   Does not prevent the 'HttpSetCookie' header from being sent if cookies have been
--   set for this request with 'setCookie'.
unsetResponseHeader
    :: (MonadFastCGI m)
    => Header -- ^ The header to unset.  Must be a response header or an entity header.
    -> m ()
unsetResponseHeader header = do
  requireResponseHeadersNotYetSent
  if isValidInResponse header
    then do
      FastCGIState { request = Just request } <- getFastCGIState
      responseHeaderMap <- liftIO $ takeMVar $ responseHeaderMapMVar request
      let responseHeaderMap' = Map.delete header responseHeaderMap
      liftIO $ putMVar (responseHeaderMapMVar request) responseHeaderMap'
    else fThrow $ NotAResponseHeader header


-- | Returns the value of the given header which will be or has been sent with the
--   response headers.  If the header is not an HTTP/1.1 or extension response or entity
--   header, ie, is not valid as part of a response, causes a 'NotAResponseHeader'
--   exception.
getResponseHeader
    :: (MonadFastCGI m)
    => Header -- ^ The header to query.  Must be a response header or an entity
              --   header.
    -> m (Maybe String) -- ^ The value of the queried header.
getResponseHeader header = do
  requireResponseHeadersNotYetSent
  if isValidInResponse header
    then do
      FastCGIState { request = Just request } <- getFastCGIState
      responseHeaderMap <- liftIO $ readMVar $ responseHeaderMapMVar request
      return $ Map.lookup header responseHeaderMap
    else fThrow $ NotAResponseHeader header


-- | Causes the user agent to record the given cookie and send it back with future
--   loads of this page.  Does not take effect instantly, but rather when headers are
--   sent.  Cookies are set in accordance with RFC 2109.
--   If an @HttpCookie@ header is set for this request by a call to 'setResponseHeader',
--   this function has no effect.
--   If the response headers have already been sent,
--   causes a 'ResponseHeadersAlreadySent' exception.
--   If the name is not a possible name for a cookie, causes a 'CookieNameInvalid'
--   exception.
setCookie
    :: (MonadFastCGI m)
    => Cookie -- ^ The cookie to set.
    -> m ()
setCookie cookie = do
  requireResponseHeadersNotYetSent
  requireValidCookieName $ cookieName cookie
  FastCGIState { request = Just request } <- getFastCGIState
  responseCookieMap <- liftIO $ takeMVar $ responseCookieMapMVar request
  let responseCookieMap' = Map.insert (cookieName cookie) cookie responseCookieMap
  liftIO $ putMVar (responseCookieMapMVar request) responseCookieMap'


-- | Causes the user agent to unset any cookie applicable to this page with the
--   given name.  Does not take effect instantly, but rather when headers are sent.
--   If an @HttpCookie@ header is set for this request by a call to 'setResponseHeader',
--   this function has no effect.
--   If the response headers have already been sent,
--   causes a 'ResponseHeadersAlreadySent' exception.
--   If the name is not a possible name for a cookie, causes a 'CookieNameInvalid'
--   exception.
unsetCookie
    :: (MonadFastCGI m)
    => String -- ^ The name of the cookie to unset.
    -> m ()
unsetCookie name = do
  requireResponseHeadersNotYetSent
  requireValidCookieName name
  FastCGIState { request = Just request } <- getFastCGIState
  responseCookieMap <- liftIO $ takeMVar $ responseCookieMapMVar request
  let responseCookieMap' = Map.insert name (mkUnsetCookie name) responseCookieMap
  liftIO $ putMVar (responseCookieMapMVar request) responseCookieMap'


-- | Constructs a cookie with the given name and value.  Version is set to 1;
--   path, domain, and maximum age are set to @Nothing@; and the secure flag is
--   set to @False@.  Constructing the cookie does not cause it to be set; to do
--   that, call 'setCookie' on it.
mkSimpleCookie
    :: String -- ^ The name of the cookie to construct.
    -> String -- ^ The value of the cookie to construct.
    -> Cookie -- ^ A cookie with the given name and value.
mkSimpleCookie name value = Cookie {
                              cookieName = name,
                              cookieValue = value,
                              cookieVersion = 1,
                              cookiePath = Nothing,
                              cookieDomain = Nothing,
                              cookieMaxAge = Nothing,
                              cookieSecure = False,
                              cookieComment = Nothing
                            }


-- | Constructs a cookie with the given parameters.  Version is set to 1.
--   Constructing the cookie does not cause it to be set; to do that, call 'setCookie'
--   on it.
mkCookie
    :: String -- ^ The name of the cookie to construct.
    -> String -- ^ The value of the cookie to construct.
    -> (Maybe String) -- ^ The path of the cookie to construct.
    -> (Maybe String) -- ^ The domain of the cookie to construct.
    -> (Maybe Int) -- ^ The maximum age of the cookie to construct, in seconds.
    -> Bool -- ^ Whether to flag the cookie to construct as secure.
    -> Cookie -- ^ A cookie with the given parameters.
mkCookie name value maybePath maybeDomain maybeMaxAge secure
    = Cookie {
        cookieName = name,
        cookieValue = value,
        cookieVersion = 1,
        cookiePath = maybePath,
        cookieDomain = maybeDomain,
        cookieMaxAge = maybeMaxAge,
        cookieSecure = secure,
        cookieComment = Nothing
      }


mkUnsetCookie :: String -> Cookie
mkUnsetCookie name  = Cookie {
                              cookieName = name,
                              cookieValue = "",
                              cookieVersion = 1,
                              cookiePath = Nothing,
                              cookieDomain = Nothing,
                              cookieMaxAge = Just 0,
                              cookieSecure = False,
                              cookieComment = Nothing
                            }


requireValidCookieName :: (MonadFastCGI m) => String -> m ()
requireValidCookieName name = do
  if not $ isValidCookieToken name
    then fThrow $ CookieNameInvalid name
    else return ()


isValidCookieToken :: String -> Bool
isValidCookieToken token =
    let validCharacter c = (ord c > 0) && (ord c < 128)
                           && (not $ elem c "()<>@,;:\\\"/[]?={} \t")
    in (length token > 0) && (all validCharacter token)


-- | An exception originating within the FastCGI infrastructure or the web server.
data FastCGIException
    = ResponseHeadersAlreadySent
      -- ^ An exception thrown by operations which require the response headers not
      --   to have been sent yet.
    | OutputAlreadyClosed
      -- ^ An exception thrown by operations which produce output when output has
      --   been closed, as by 'fCloseOutput'.
    | NotAResponseHeader Header
      -- ^ An exception thrown by operations which are given a header that does not
      --   meet their requirement of being valid in a response.
    | CookieNameInvalid String
      -- ^ An exception thrown by operations which are given cookie names that do not
      --   meet the appropriate syntax requirements.
      deriving (Show, Typeable)


instance Exception.Exception FastCGIException


-- | Sets the HTTP/1.1 return status to 301 and sets the 'HttpLocation' header to
--   the provided URL.  This has the effect of issuing a permanent redirect to the
--   user agent.  Permanent redirects, as opposed to temporary redirects, may cause
--   bookmarks or incoming links to be updated.  If the response headers have already
--   been sent, causes a 'ResponseHeadersAlreadySent' exception.
permanentRedirect
    :: (MonadFastCGI m)
    => String -- ^ The URL to redirect to, as a string.
    -> m ()
permanentRedirect url = do
  setResponseStatus 301
  setResponseHeader HttpLocation url


-- | Sets the HTTP/1.1 return status to 303 and sets the 'HttpLocation' header to
--   the provided URL.  This has the effect of issuing a see-other or "temporary"
--   redirect to the user agent.  Temporary redirects, as opposed to permanent redirects,
--   do not cause bookmarks or incoming links to be updated.  If the response headers
--   have already been sent, causes a 'ResponseHeadersAlreadySent' exception.
seeOtherRedirect
    :: (MonadFastCGI m)
    => String -- ^ The URL to redirect to, as a string.
    -> m ()
seeOtherRedirect url = do
  setResponseStatus 303
  setResponseHeader HttpLocation url


-- | Ensures that the response headers have been sent.  If they are already sent, does
--   nothing.  If output has already been closed, causes an 'OutputAlreadyClosed'
--   exception.
sendResponseHeaders :: (MonadFastCGI m) => m ()
sendResponseHeaders = do
  requireOutputNotYetClosed
  FastCGIState { request = Just request } <- getFastCGIState
  alreadySent <- liftIO $ takeMVar $ responseHeadersSentMVar request
  if not alreadySent
    then do
      responseStatus <- liftIO $ readMVar $ responseStatusMVar request
      responseHeaderMap <- liftIO $ readMVar $ responseHeaderMapMVar request
      responseCookieMap <- liftIO $ readMVar $ responseCookieMapMVar request
      let nameValuePairs = [("Status", (show responseStatus))]
                           ++ (map (\key -> (fromHeader key,
                                             fromJust $ Map.lookup key responseHeaderMap))
                                   $ Map.keys responseHeaderMap)
                           ++ (if (isNothing $ Map.lookup HttpSetCookie
                                                          responseHeaderMap)
                                  && (length (Map.elems responseCookieMap) > 0)
                                 then [("Set-Cookie", setCookieValue)]
                                 else [])
          setCookieValue = printCookies $ Map.elems responseCookieMap
          bytestrings
              = (map (\(name, value) -> BS.fromString $ name ++ ": " ++ value ++ "\r\n")
                     nameValuePairs)
                ++ [BS.fromString "\r\n"]
          buffer = foldl BS.append BS.empty bytestrings
      sendBuffer buffer
    else return ()
  liftIO $ putMVar (responseHeadersSentMVar request) True


-- | Returns whether the response headers have been sent.
responseHeadersSent :: (MonadFastCGI m) => m Bool
responseHeadersSent = do
  FastCGIState { request = Just request } <- getFastCGIState
  liftIO $ readMVar $ responseHeadersSentMVar request


-- | Sends data.  This is the content data of the HTTP response.  If the response
--   headers have not been sent, first sends them.  If output has already been closed,
--   causes an 'OutputAlreadyClosed' exception.
fPut :: (MonadFastCGI m) => BS.ByteString -> m ()
fPut buffer = do
  requireOutputNotYetClosed
  sendResponseHeaders
  sendBuffer buffer
  return ()


-- | Sends text, encoded as UTF-8.  This is the content data of the HTTP response.
--   if the response headers have not been sent, first sends them.  If output has
--   already been closed, causes an 'OutputAlreadyClosed' exception.
fPutStr :: (MonadFastCGI m) => String -> m ()
fPutStr string = fPut $ BS.fromString string


-- | Informs the web server and the user agent that the request has completed.  As
--   side-effects, the response headers are sent if they have not yet been, and
--   any unread input is discarded and no more can be read.  This is
--   implicitly called, if it has not already been, after the handler returns; it
--   may be useful within a handler if the handler wishes to return results and then
--   perform time-consuming computations before exiting.  If output has already been
--   closed, causes an 'OutputAlreadyClosed' exception.
fCloseOutput :: (MonadFastCGI m) => m ()
fCloseOutput = do
  requireOutputNotYetClosed
  sendResponseHeaders
  terminateRequest


-- | Returns whether it is possible to write more data; ie, whether output has not
--   yet been closed as by 'fCloseOutput'.
fIsWritable :: (MonadFastCGI m) => m Bool
fIsWritable = do
  FastCGIState { request = Just request } <- getFastCGIState
  requestEnded <- liftIO $ readMVar $ requestEndedMVar request
  return $ not requestEnded


sendBuffer :: (MonadFastCGI m) => BS.ByteString -> m ()
sendBuffer buffer = do
  let length = BS.length buffer
      lengthThisRecord = minimum [length, 0xFFFF]
      bufferThisRecord = BS.take lengthThisRecord buffer
      bufferRemaining = BS.drop lengthThisRecord buffer
  if lengthThisRecord > 0
    then do
      FastCGIState { request = Just request } <- getFastCGIState
      sendRecord $ Record {
                       recordType = StdoutRecord,
                       recordRequestID = requestID request,
                       recordContent = bufferThisRecord
                     }
    else return ()
  if length > lengthThisRecord
    then sendBuffer bufferRemaining
    else return ()


terminateRequest :: (MonadFastCGI m) => m ()
terminateRequest = do
  FastCGIState { request = Just request } <- getFastCGIState
  sendRecord $ Record {
                     recordType = EndRequestRecord,
                     recordRequestID = requestID request,
                     recordContent = BS.pack [0, 0, 0, 0, 0, 0, 0, 0]
                   }


requireResponseHeadersNotYetSent :: (MonadFastCGI m) => m ()
requireResponseHeadersNotYetSent = do
  FastCGIState { request = Just request } <- getFastCGIState
  alreadySent <- liftIO $ readMVar $ responseHeadersSentMVar request
  if alreadySent
    then fThrow ResponseHeadersAlreadySent
    else return ()


requireOutputNotYetClosed :: (MonadFastCGI m) => m ()
requireOutputNotYetClosed = do
  FastCGIState { request = Just request } <- getFastCGIState
  requestEnded <- liftIO $ readMVar $ requestEndedMVar request
  if requestEnded
    then fThrow OutputAlreadyClosed
    else return ()


-- | Throw an exception in any 'MonadFastCGI' monad.
fThrow
    :: (Exception.Exception e, MonadFastCGI m)
    => e -- ^ The exception to throw.
    -> m a
fThrow exception = implementationThrowFastCGI exception


-- | Perform an action, with a given exception-handler action bound.  See
--   'Control.Exception.catch'.  The type of exception to catch is determined by the
--   type signature of the handler.
fCatch
    :: (Exception.Exception e, MonadFastCGI m)
    => m a -- ^ The action to run with the exception handler binding in scope.
    -> (e -> m a) -- ^ The exception handler to bind.
    -> m a
fCatch action handler = implementationCatchFastCGI action handler


-- | Block exceptions within an action, as per the discussion in 'Control.Exception'.
fBlock
    :: (MonadFastCGI m)
    => m a -- ^ The action to run with exceptions blocked.
    -> m a
fBlock action = implementationBlockFastCGI action


-- | Unblock exceptions within an action, as per the discussion in 'Control.Exception'.
fUnblock
    :: (MonadFastCGI m)
    => m a -- ^ The action to run with exceptions unblocked.
    -> m a
fUnblock action = implementationUnblockFastCGI action


-- | Acquire a resource, perform computation with it, and release it; see the description
--   of 'Control.Exception.bracket'.  If an exception is raised during the computation,
--   'fBracket' will re-raise it after running the release function, having the effect
--   of propagating the exception further up the call stack.
fBracket
    :: (MonadFastCGI m)
    => m a -- ^ The action to acquire the resource.
    -> (a -> m b) -- ^ The action to release the resource.
    -> (a -> m c) -- ^ The action to perform using the resource.
    -> m c -- ^ The return value of the perform-action.
fBracket acquire release perform = do
  fBlock (do
           resource <- acquire
           result <- fUnblock (perform resource) `fOnException` (release resource)
           release resource
           return result)


-- | Perform an action, with a cleanup action bound to always occur; see the
--   description of 'Control.Exception.finally'.  If an exception is raised during the
--   computation, 'fFinally' will re-raise it after running the cleanup action, having
--   the effect of propagating the exception further up the call stack.  If no
--   exception is raised, the cleanup action will be invoked after the main action is
--   performed.
fFinally
    :: (MonadFastCGI m)
    => m a -- ^ The action to perform.
    -> m b -- ^ The cleanup action.
    -> m a -- ^ The return value of the perform-action.
fFinally perform cleanup = do
  fBlock (do
           result <- fUnblock perform `fOnException` cleanup
           cleanup
           return result)


-- | Perform an action.  If any exceptions of the appropriate type occur within the
--   action, return 'Left' @exception@; otherwise, return 'Right' @result@.
fTry
    :: (Exception.Exception e, MonadFastCGI m)
    => m a -- ^ The action to perform.
    -> m (Either e a)
fTry action = do
  fCatch (do
           result <- action
           return $ Right result)
         (\exception -> return $ Left exception)


-- | As 'fCatch', but with the arguments in the other order.
fHandle
    :: (Exception.Exception e, MonadFastCGI m)
    => (e -> m a) -- ^ The exception handler to bind.
    -> m a -- ^ The action to run with the exception handler binding in scope.
    -> m a
fHandle handler action = fCatch action handler


-- | Perform an action, with a cleanup action bound to occur if and only if an exception
--   is raised during the action; see the description of 'Control.Exception.finally'.
--   If an exception is raised during the computation, 'fFinally' will re-raise it
--   after running the cleanup action, having the effect of propagating the exception
--   further up the call stack.  If no exception is raised, the cleanup action will not
--   be invoked.
fOnException
    :: (MonadFastCGI m)
    => m a -- ^ The action to perform.
    -> m b -- ^ The cleanup action.
    -> m a -- ^ The return value of the perform-action.
fOnException action cleanup = do
  fCatch action
         (\exception -> do
            cleanup
            fThrow (exception :: Exception.SomeException))
