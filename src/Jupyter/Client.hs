{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
module Jupyter.Client (Client, runClient, sendClientRequest, sendClientComm, ClientHandlers(..), writeProfile) where

import           Data.Maybe (fromMaybe)
import           Data.ByteString (ByteString)
import           Control.Monad (forever)

import           Control.Monad.Reader (MonadReader, ReaderT, runReaderT, ask)
import           Control.Monad.IO.Class (MonadIO(..))
import           Control.Monad.Trans.Control (liftBaseWith)
import           Control.Monad.Catch (MonadThrow, MonadCatch, MonadMask)
import           Data.Aeson (encode)
import qualified Data.ByteString.Lazy as LBS
import           Control.Exception (throwIO, SomeException, bracket, catch,
                                    AsyncException(ThreadKilled))

import           Control.Concurrent.Async (async, link, link2, cancel, Async)

import           Jupyter.ZeroMQ (ClientSockets(..), withClientSockets, sendMessage, receiveMessage,
                                 messagingError, mkRequestHeader, KernelProfile(..), mkReplyHeader)
import           Jupyter.Messages (Comm, KernelRequest, ClientReply, KernelOutput, ClientRequest,
                                   KernelReply)
import           Jupyter.Messages.Metadata (Username)
import qualified Jupyter.UUID as UUID

import           System.ZMQ4.Monadic (ZMQ)

writeProfile :: KernelProfile -> FilePath -> IO ()
writeProfile profile path = LBS.writeFile path (encode profile) 

data ClientState = forall z.
       ClientState
         { clientSockets :: ClientSockets z
         , clientSessionUsername :: Username
         , clientSessionUuid :: UUID.UUID
         , clientSignatureKey :: ByteString
         , clientLiftZMQ :: forall a m. MonadIO m => ZMQ z a -> m a
         }

newtype Client a = Client { unClient :: ReaderT ClientState IO a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader ClientState, MonadThrow, MonadCatch, MonadMask)

data ClientHandlers =
       ClientHandlers
         { kernelRequestHandler :: (Comm -> IO ()) -> KernelRequest -> IO ClientReply
         , commHandler :: (Comm -> IO ()) -> Comm -> IO ()
         , kernelOutputHandler :: (Comm -> IO ()) -> KernelOutput -> IO ()
         }

runClient :: Maybe KernelProfile -> Maybe Username -> ClientHandlers -> (KernelProfile -> Client a) -> IO a
runClient mProfile mUser clientHandlers client =
  withClientSockets mProfile $ \profile sockets ->
    liftBaseWith $ \runInBase -> do
      let sessionUsername = fromMaybe "default-username" mUser
      sessionUuid <- UUID.random
      let clientState = ClientState
            { clientSockets = sockets
            , clientSessionUsername = sessionUsername
            , clientSessionUuid = sessionUuid
            , clientSignatureKey = profileSignatureKey profile
            , clientLiftZMQ = liftIO . runInBase
            }

      let setupListeners = do
            async1 <- listenStdin clientState clientHandlers
            async2 <- listenIopub clientState clientHandlers

            -- Ensure that if any exceptions are thrown on the handler threads,
            -- those exceptions are re-raised on the main thread.
            link async1
            link2 async1 async2

            return (async1, async2)

      -- Ensure that if any exceptions are thrown on the main thread, the asyncs
      -- are cancelled with a ThreadKilled exception, and that if no exceptions
      -- are thrown, then the threads are terminated as appropriate.
      bracket setupListeners
              (\(async1, async2) -> cancel async1 >> cancel async2)
              (const $ runReaderT (unClient $ client profile) clientState)

threadKilledHandler :: AsyncException -> IO ()
threadKilledHandler ThreadKilled = return ()
threadKilledHandler ex = throwIO ex

listenIopub :: ClientState -> ClientHandlers -> IO (Async ())
listenIopub ClientState { .. } handlers = async $ catch (forever respondIopub) threadKilledHandler
  where
    respondIopub = do
      received <- clientLiftZMQ $ receiveMessage (clientIopubSocket clientSockets)
      case received of
        Left err ->
          -- There's no way to recover from this, so just die.
          messagingError "Jupyter.Client" $
            "Unexpected failure parsing Comm or KernelOutput message: " ++ err
        Right (header, message) -> do
          let sendReplyComm comm = do
                commHeader <- mkReplyHeader header comm
                clientLiftZMQ $ sendMessage
                                  clientSignatureKey
                                  (clientShellSocket clientSockets)
                                  commHeader
                                  comm

          case message of
            Left comm    -> commHandler handlers sendReplyComm comm
            Right output -> kernelOutputHandler handlers sendReplyComm output

listenStdin :: ClientState -> ClientHandlers -> IO (Async ())
listenStdin ClientState{..} handlers = async $ catch (forever respondStdin) threadKilledHandler
  where
    respondStdin = do
      received <- clientLiftZMQ $ receiveMessage (clientStdinSocket clientSockets)
      case received of
        Left err ->
          -- There's no way to recover from this, so just die.
          messagingError "Jupyter.Client" $
            "Unexpected failure parsing KernelRequest message: " ++ err
        Right (header, message) -> do
          let sendReplyComm comm = do
                commHeader <- mkReplyHeader header comm
                clientLiftZMQ $ sendMessage clientSignatureKey (clientShellSocket clientSockets) commHeader comm
          reply <- kernelRequestHandler handlers sendReplyComm message
          replyHeader <- mkReplyHeader header reply
          clientLiftZMQ $ sendMessage clientSignatureKey (clientStdinSocket clientSockets) replyHeader reply

sendClientRequest :: ClientRequest -> Client KernelReply
sendClientRequest req = do
  ClientState { .. } <- ask
  header <- liftIO $ mkRequestHeader clientSessionUuid clientSessionUsername req
  clientLiftZMQ $ sendMessage clientSignatureKey (clientShellSocket clientSockets) header req
  received <- clientLiftZMQ $ receiveMessage (clientShellSocket clientSockets)

  case received of
    Left err ->
      -- There's no way to recover from this, so just die.
      messagingError "Jupyter.Client" $
        "Unexpected failure parsing KernelReply message: " ++ err
    Right (_, message) -> return message

sendClientComm :: Comm -> Client ()
sendClientComm comm = do
  ClientState { .. } <- ask
  header <- liftIO $ mkRequestHeader clientSessionUuid clientSessionUsername  comm
  clientLiftZMQ $ sendMessage clientSignatureKey (clientShellSocket clientSockets) header comm
