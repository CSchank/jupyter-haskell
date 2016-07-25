{-|
Module      : Jupyter.Kernel
Description : Functions for creating and serving a Jupyter kernel.
Copyright   : (c) Andrew Gibiansky, 2016
License     : MIT
Maintainer  : andrew.gibiansky@gmail.com
Stability   : stable
Portability : POSIX

The 'Jupyter.Kernel' module is the core of the @jupyter-kernel@ package, and allows you to quickly and easily create Jupyter kernels.

The main entrypoint is the 'serve' function, which provides a type-safe implementation of the Jupyter messaging spec: Given a 'ClientRequestHandler' and a 'CommHandler', serve a Jupyter kernel.
-}

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE OverloadedStrings #-}
module Jupyter.Kernel (
  -- * Defining a kernel
  CommHandler,
  ClientRequestHandler,
  simpleKernelInfo,

  -- * Serving kernels
  serve,
  serveWithDynamicPorts,
  KernelProfile(..),
  readProfile,
  KernelCallbacks(..), 
  defaultClientRequestHandler,
  defaultCommHandler,
  ) where

import           Control.Monad (forever)
import           System.IO (hPutStrLn, stderr)
import           Data.ByteString (ByteString)
import           Data.Text (Text)

import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Trans.Control (liftBaseWith)

import           Control.Concurrent.Async (link2, waitAny)

import           System.ZMQ4.Monadic (ZMQ, Socket, Rep, Router, Pub, async, receive, send)

import           Jupyter.Messages (KernelOutput, Comm, ClientRequest(..), KernelReply(..),
                                   pattern ExecuteOk, pattern InspectOk, pattern CompleteOk,
                                   CursorRange(..), CodeComplete(..), CodeOffset(..), ConnectInfo(..),
                                   KernelInfo(..), LanguageInfo(..), KernelOutput(..),
                                   KernelStatus(..), KernelRequest(..), ClientReply(..))
import           Jupyter.ZeroMQ (withKernelSockets, KernelSockets(..), sendMessage, receiveMessage,
                                 KernelProfile(..), readProfile, messagingError)

-- | Create the simplest possible 'KernelInfo'.
--
-- Defaults version numbers to \"0.0\", mimetype to \"text/plain\", empty banner, and a \".txt\"
-- file extension.
--
-- Mostly intended for use in tutorials and demonstrations; if publishing production kernels, make
-- sure to use the full 'KernelInfo' constructor.
simpleKernelInfo :: Text -- ^ Kernel name, used for 'kernelImplementation' and 'languageName'.
                 -> KernelInfo
simpleKernelInfo kernelName =
  KernelInfo
    { kernelProtocolVersion = "5.0"
    , kernelBanner = ""
    , kernelImplementation = kernelName
    , kernelImplementationVersion = "0.0"
    , kernelHelpLinks = []
    , kernelLanguageInfo = LanguageInfo
      { languageName = kernelName
      , languageVersion = "0.0"
      , languageMimetype = "text/plain"
      , languageFileExtension = ".txt"
      , languagePygmentsLexer = Nothing
      , languageCodeMirrorMode = Nothing
      , languageNbconvertExporter = Nothing
      }
    }


-- | The 'KernelCallbacks' data type contains callbacks that the kernel may use to communicate with
-- the client. Specifically, it can send 'KernelOutput' and 'Comm' messages using 'sendKernelOutput'
-- and 'sendComm', respectively, which are often sent to frontends in response to 'ExecuteRequest'
-- messsages.
--
-- In addition, 'sentKernelRequest' can be used to send a 'KernelRequest' to the client, and
-- synchronously wait and receive a 'ClientReply'.
data KernelCallbacks =
       KernelCallbacks
         { sendKernelOutput :: KernelOutput -> IO () -- ^ Publish an output to all connected
                                                     -- frontends. This is the primary mechanism by
                                                     -- which a kernel shows output to the user.
         , sendComm :: Comm -> IO () -- ^ Publish a 'Comm' message to the frontends. This allows for
                                     -- entirely freeform back-and-forth communication between
                                     -- frontends and kernels, avoiding the structure of the Jupyter
                                     -- messaging protocol. This can be used for implementing custom
                                     -- features such as support for the Jupyter notebook widgets.
         , sendKernelRequest :: KernelRequest -> IO ClientReply -- ^ Send a 'KernelRequest' to the
                                                                -- client that send the first message
                                                                -- and wait for it to reply with a
                                                                -- 'ClientReply'.
         }

-- | When calling 'serve', the caller must provide a 'CommHandler'.
--
-- The handler is used when the kernel receives a 'Comm' message from a frontend; the 'Comm' message
-- is passed to the handler, along with a set of callbacks the handler may use to send messages to
-- the client.
--
-- Since 'Comm's are used for free-form communication outside the messaging spec, kernels should
-- ignore 'Comm' messages they do not expect.
--
-- The 'defaultCommHandler' handler is provided for use with kernels that wish to ignore all 'Comm'
-- messages.
type CommHandler = KernelCallbacks -> Comm -> IO ()

-- | When calling 'serve', the caller must provide a 'ClientRequestHandler'.
--
-- The handler is used when the kernel receives a 'ClientRequest' message from a frontend; the
-- 'ClientRequest' message is passed to the handler, along with a set of callbacks the handler may
-- use to send messages to the client.
--
-- The handler must return a 'KernelReply' to be sent in response to this request. 'ClientRequest'
-- and 'KernelReply' constructors come in pairs, and the output reply constructor *must* match the
-- input request constructor.
--
-- Note: When the request is a 'ExecuteRequest' with the 'executeSilent' option set to @True@, the
-- 'KernelReply' will not be sent.
type ClientRequestHandler = KernelCallbacks -> ClientRequest -> IO KernelReply

-- | Handler which ignores all 'Comm' messages sent to the kernel (and does nothing).
defaultCommHandler :: CommHandler
defaultCommHandler _ _ = return ()

-- | Handler which responds to all 'ClientRequest' messages with a default, empty reply.
defaultClientRequestHandler :: KernelProfile -- ^ The profile this kernel is running on. Used to respond to 'ConnectRequest's.
                            -> KernelInfo    -- ^ Information about this kernel. Used to respond to 'KernelInfoRequest's.
                            -> ClientRequestHandler
defaultClientRequestHandler KernelProfile{..} kernelInfo _ req =
  return $
    case req of
      ExecuteRequest{} -> ExecuteReply 0 ExecuteOk
      InspectRequest{} -> InspectReply $ InspectOk Nothing
      HistoryRequest{} -> HistoryReply []
      CompleteRequest _ (CodeOffset offset) ->
        CompleteReply $ CompleteOk [] (CursorRange offset offset) mempty
      IsCompleteRequest{} -> IsCompleteReply CodeUnknown
      CommInfoRequest{} -> CommInfoReply mempty
      ShutdownRequest restart -> ShutdownReply restart
      KernelInfoRequest{} -> KernelInfoReply kernelInfo
      ConnectRequest{} -> ConnectReply
                            ConnectInfo
                              { connectShellPort = profileShellPort
                              , connectIopubPort = profileIopubPort
                              , connectHeartbeatPort = profileHeartbeatPort
                              , connectStdinPort = profileStdinPort
                              }

-- | Indefinitely serve a kernel on the provided ports. If the ports are not open, fails with an
-- exception.
--
-- This starts several threads which listen and write to ZeroMQ sockets on the ports indicated in
-- the 'KernelProfile'. If an exception is raised and any of the threads die, the exception is
-- re-raised on the main thread. Otherwise, this listens on the kernels indefinitely.
serve :: KernelProfile         -- ^ The kernel profile specifies how to listen for client messages (ports,
                               -- transport mechanism, message signing, etc).
      -> CommHandler           -- ^ The 'Comm' handler is called when 'Comm' messages are received from a
                               -- frontend.
      -> ClientRequestHandler  -- ^The request handler is called when 'ClientRequest' messages are
                               -- received from a frontend.
      -> IO a
serve profile = serveInternal (Just profile) (const $ return ())

-- | Indefinitely serve a kernel on some ports. Ports are allocated dynamically and so, unlike
-- 'serve', 'serveWithDynamicPorts' may be used when you do not know which ports are open or closed.
--
-- The ports allocated by 'serveWithDynamicPorts' are passed to the provided callback in the
-- 'KernelProfile' so that clients may connect to the served kernel.
--
-- After the callback is run, several threads are started which listen and write to ZeroMQ sockets
-- on the allocated ports. If an exception is raised and any of the threads die, the exception is
-- re-raised on the main thread. Otherwise, this listens on the kernels indefinitely after running
-- the callback.
serveWithDynamicPorts :: (KernelProfile -> IO ()) -- ^ This function is called with the
                                                  -- dynamically-generated kernel profile that the
                                                  -- kernel will serve on, so that clients may be
                                                  -- notified of which ports to use to connect to
                                                  -- this kernel. The callback is called after
                                                  -- sockets are bound but before the kernel begins
                                                  -- listening for messages, so if the callback fails
                                                  -- with an exception the kernel threads are never
                                                  -- started.
                      -> CommHandler           -- ^ The 'Comm' handler is called when 'Comm' messages are
                                               -- received from a frontend.
                      -> ClientRequestHandler  -- ^The request handler is called when 'ClientRequest'
                                               -- messages are received from a frontend.
                      -> IO a
serveWithDynamicPorts = serveInternal Nothing


-- | Serve a kernel.
--
-- If a 'KernelProfile' is provided, then open sockets bound to the specified ports; otherwise,
-- dynamically allocate ports and bind sockets to them. In both cases, the final 'KernelProfile'
-- used is passed to the provided callback, so that clients can be informed about how to connect to
-- this kernel.
--
-- Users of the library should use 'serve' or 'serveWithDynamicPorts' instead.
--
-- After the callback is run, several threads are started which listen and write to ZeroMQ sockets
-- on the allocated ports. If an exception is raised and any of the threads die, the exception is
-- re-raised on the main thread. Otherwise, this listens on the kernels indefinitely after running
-- the callback.
serveInternal :: Maybe KernelProfile
              -> (KernelProfile -> IO ())
              -> CommHandler
              -> ClientRequestHandler
              -> IO a
serveInternal mProfile profileHandler commHandler requestHandler =
  withKernelSockets mProfile $ \profile KernelSockets { .. } -> do
    -- If anything is going to be done with the profile information, do it now, after sockets have been
    -- bound but before we start listening on them infinitely.
    liftIO $ profileHandler profile

    let key = profileSignatureKey profile
        loop = async . forever
        handlers = (commHandler, requestHandler)

    -- Start all listening loops in separate threads.
    async1 <- loop $ echoHeartbeat kernelHeartbeatSocket
    async2 <- loop $ serveRouter kernelControlSocket key kernelIopubSocket kernelStdinSocket handlers
    async3 <- loop $ serveRouter kernelShellSocket key kernelIopubSocket kernelStdinSocket handlers

    -- Make sure that a fatal exception on any thread kills all threads.
    liftIO $ do
      link2 async1 async2
      link2 async2 async3
      link2 async3 async1

    -- Wait indefinitely; if any of the threads encounter a fatal exception, the fatal exception is
    -- re-raised on the main thread.
      snd <$> waitAny [async1, async2, async3]

-- | Heartbeat once.
--
-- To heartbeat, listen for a message on the socket, and when you receive one, immediately write it
-- back to the same socket.
echoHeartbeat :: Socket z Rep -> ZMQ z ()
echoHeartbeat heartbeatSocket =
  receive heartbeatSocket >>= send heartbeatSocket []

-- | Receive and respond to a single message on the /shell/ or /control/ sockets.
serveRouter :: Socket z Router  -- ^ The /shell/ or /control/ socket to listen on and write to
            -> ByteString       -- ^ The signature key to sign messages with
            -> Socket z Pub     -- ^ The /iopub/ socket to publish outputs to
            -> Socket z Router  -- ^ The /stdin/ socket to use to get input from the client
            -> (CommHandler, ClientRequestHandler) -- ^ The handlers to use to respond to messages
            -> ZMQ z ()
serveRouter sock key iopub stdin handlers =
  -- We use 'liftBaseWith' and the resulting 'RunInBase' from the 'MonadBaseControl' class in order to
  -- hide from the kernel implementer the fact that all of this is running in the ZMQ monad. This ends
  -- up being very straightforward, because the ZMQ monad is a very thin layer over IO.
  liftBaseWith $ \runInBase -> do
    received <- runInBase $ receiveMessage sock
    case received of
      Left err -> liftIO $ hPutStrLn stderr $ "Error receiving message: " ++ err
      Right (header, message) ->
        -- After receiving a message, create the publisher callbacks which use that message as the "parent"
        -- for any responses they generate. This means that when outputs are generated in response to a
        -- message, they automatically inherit that message as a parent.
        let publishers = KernelCallbacks
              { sendComm = runInBase . sendMessage key iopub header
              , sendKernelOutput = runInBase . sendMessage key iopub header
              , sendKernelRequest = runInBase . stdinCommunicate header
              }
            sendReply = runInBase . sendMessage key sock header
        in handleRequest sendReply publishers handlers message
  where
    stdinCommunicate header req = do
      sendMessage key stdin header req
      received <- receiveMessage stdin
      case received of
        Left err ->
          -- There's no way to recover from this, so just die.
          messagingError "Jupyter.Kernel" $ "Unexpected failure parsing ClientReply message: " ++ err
        Right (_, message) -> return message

-- | Handle a request using the appropriate handler.
--
-- A request may either be a 'ClientRequest' or a 'Comm', which correspond to the
-- 'ClientRequestHandler' and the 'CommHandler' respectively. In the case of a 'ClientRequest', the
-- 'KernelReply' is also sent back to the frontend.
handleRequest :: (KernelReply -> IO ()) -- ^ Callback to send reply messages to the frontend
              -> KernelCallbacks -- ^ Callbacks for publishing outputs to frontends
              -> (CommHandler, ClientRequestHandler) -- ^ Handlers for messages from frontends
              -> Either ClientRequest Comm -- ^ The received message content
              -> IO ()
handleRequest sendReply publishers (commHandler, requestHandler) message =
  case message of
    Left clientRequest ->
      let handle = requestHandler publishers clientRequest >>= sendReply
      in case clientRequest of
        ExecuteRequest{} -> do
          sendKernelOutput publishers $ KernelStatusOutput KernelBusy
          handle
          sendKernelOutput publishers $ KernelStatusOutput KernelIdle
        _ -> handle

    Right comm -> commHandler publishers comm
