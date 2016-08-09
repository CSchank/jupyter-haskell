{-# LANGUAGE OverloadedStrings #-}
module Jupyter.Test.Kernel (kernelTests) where

-- Imports from 'base'
import           Control.Concurrent (newEmptyMVar, MVar, forkIO, putMVar, takeMVar, readMVar,
                                     killThread)
import           Control.Exception (throwIO)
import           Control.Monad (forM_, void)
import           Data.Proxy (Proxy(Proxy))

-- Imports from 'async'
import           Control.Concurrent.Async (async, wait, cancel)

-- Imports from 'transformers'
import           Control.Monad.IO.Class (liftIO)

-- Imports from 'tasty'
import           Test.Tasty (TestTree, testGroup)

-- Imports from 'tasty-hunit'
import           Test.Tasty.HUnit (testCase, testCaseSteps, (@=?))

-- Imports from 'aeson'
import           Data.Aeson (object)

-- Imports from 'zeromq4-haskell'
import           System.ZMQ4.Monadic (Req(..), Dealer(..), send, receive, runZMQ, ZMQError)

-- Imports from 'jupyter'
import           Jupyter.Kernel
import           Jupyter.Messages
import           Jupyter.Messages.Internal
import           Jupyter.ZeroMQ
import qualified Jupyter.UUID as UUID

import           Jupyter.Test.Utils (connectedSocket, shouldThrow, HandlerException(..))

kernelTests :: TestTree
kernelTests = testGroup "Kernel Tests" [testKernel, testKernelPortsTaken, testKernelExceptions]

testKernelPortsTaken :: TestTree
testKernelPortsTaken = testCase "Kernel Ports Taken" $ do
  profileVar <- newEmptyMVar
  let reqHandler cb req = do
        profile <- readMVar profileVar
        defaultClientRequestHandler profile (simpleKernelInfo "Test") cb req
  thread <- async $ serveWithDynamicPorts (putMVar profileVar) defaultCommHandler reqHandler
  profile <- readMVar profileVar
  serve profile defaultCommHandler reqHandler `shouldThrow` (Proxy :: Proxy ZMQError)
  cancel thread

testKernelExceptions :: TestTree
testKernelExceptions = testCaseSteps "Kernel Exceptions" $ \step -> do
  step "Testing broken request handler..."
  profileVar <- newEmptyMVar

  let sendShellMsg msg =
        runZMQ $ do
          profile <- liftIO $ readMVar profileVar
          shellClientSocket <- connectedSocket profile profileShellPort Dealer
          header <- liftIO $ mkFreshTestHeader msg
          sendMessage "" shellClientSocket header msg

  thread1 <- async $ serveWithDynamicPorts (putMVar profileVar) defaultCommHandler brokenHandler
  sendShellMsg ConnectRequest
  wait thread1 `shouldThrow` [HandlerException]

  step "Testing broken comm handler..."
  void $ takeMVar profileVar
  thread2 <- async $ serveWithDynamicPorts (putMVar profileVar) brokenHandler (reqHandler profileVar)
  sendShellMsg $ CommMessage (UUID.uuidFromString "test") (object [])
  wait thread2 `shouldThrow` [HandlerException]
 
  where
    reqHandler var cb req = do
      profile <- readMVar var
      defaultClientRequestHandler profile (simpleKernelInfo "Test") cb req

    brokenHandler _ _ = throwIO HandlerException

-- Test that messages can be sent and received on the heartbeat socket.
testKernel :: TestTree
testKernel = testCaseSteps "Simple Kernel" $ \step -> do
  -- Start serving the kernel and obtain the port info so we can connect to it.
  step "Starting kernel..."
  profileVar <- newEmptyMVar
  clientMessageVar <- newEmptyMVar
  threadId <- forkIO $ serveWithDynamicPorts (putMVar profileVar) defaultCommHandler (reqHandler profileVar clientMessageVar)
  profile <- readMVar profileVar

  runZMQ $ do
    liftIO $ step "Connecting to kernel..."
    heartbeatClientSocket <- connectedSocket profile profileHeartbeatPort Req
    shellClientSocket <- connectedSocket profile profileShellPort Dealer

    liftIO $ step "Checking heartbeat..."
    let message = "heartbeat"
    send heartbeatClientSocket [] message
    response <- receive heartbeatClientSocket
    liftIO $ message @=? response

    liftIO $ step "Checking client request encoding / decoding..."
    forM_ clientMessages $ \msg -> do
      header <- liftIO $ mkFreshTestHeader msg
      sendMessage "" shellClientSocket header msg
      received <- liftIO $ takeMVar clientMessageVar
      liftIO $ msg @=? received

  killThread threadId
  where
    kernelInfo :: KernelInfo
    kernelInfo = KernelInfo
      { kernelProtocolVersion = "1.2.3"
      , kernelBanner = "Banner"
      , kernelImplementation = "kernel"
      , kernelImplementationVersion = "1.0.0"
      , kernelHelpLinks = []
      , kernelLanguageInfo = LanguageInfo
        { languageName = "Test"
        , languageVersion = "1.0.0"
        , languageMimetype = "text/plain"
        , languageFileExtension = ".txt"
        , languagePygmentsLexer = Nothing
        , languageCodeMirrorMode = Nothing
        , languageNbconvertExporter = Nothing
        }
      }

    reqHandler :: MVar KernelProfile -> MVar ClientRequest -> ClientRequestHandler
    reqHandler profileVar clientMessageVar cb req = do
      putMVar clientMessageVar req
      profile <- readMVar profileVar
      defaultClientRequestHandler profile kernelInfo cb req

    clientMessages = [ ExecuteRequest (CodeBlock "1 + 1")
                         ExecuteOptions
                           { executeSilent = False
                           , executeStoreHistory = True
                           , executeAllowStdin = False
                           , executeStopOnError = True
                           }
                     , InspectRequest (CodeBlock "print 'X'") 5 DetailLow
                     , InspectRequest (CodeBlock "print 'X'") 5 DetailHigh
                     , HistoryRequest
                         HistoryOptions
                           { historyShowOutput = True
                           , historyRaw = True
                           , historyAccessType = HistoryTail 3
                           }
                     , HistoryRequest
                         HistoryOptions
                           { historyShowOutput = True
                           , historyRaw = True
                           , historyAccessType = HistoryRange
                                                   HistoryRangeOptions
                                                     { historyRangeSession = -1
                                                     , historyRangeStart = 10
                                                     , historyRangeStop = 100
                                                     }
                           }
                     , HistoryRequest
                         HistoryOptions
                           { historyShowOutput = True
                           , historyRaw = True
                           , historyAccessType = HistorySearch
                                                   HistorySearchOptions
                                                     { historySearchCells = 10
                                                     , historySearchPattern = "putStr*"
                                                     , historySearchUnique = True
                                                     }
                           }
                     , CompleteRequest (CodeBlock "putStrL + 3") 7
                     , IsCompleteRequest (CodeBlock "let x = 3 in")
                     , ConnectRequest
                     , CommInfoRequest Nothing
                     , CommInfoRequest (Just (TargetName "comm_target"))
                     , KernelInfoRequest
                     ]

mkFreshTestHeader :: IsMessage v => v -> IO MessageHeader
mkFreshTestHeader content = do
  uuid <- UUID.random
  sess <- UUID.random
  return
    MessageHeader
      { messageIdentifiers = ["ABC", "DEF"]
      , messageParent = Nothing
      , messageMetadata = mempty
      , messageId = uuid
      , messageSession = sess
      , messageUsername = "test-user"
      , messageType = getMessageType content
      }
