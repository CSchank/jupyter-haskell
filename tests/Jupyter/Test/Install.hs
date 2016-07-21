{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
module Jupyter.Test.Install (installTests) where

import           Data.Monoid (mempty)
import           Data.List (isInfixOf)
import           Control.Monad (forM_, (=<<))
import           System.Environment (setEnv)
import           Control.Exception (catch, Exception)
import           Data.Proxy (Proxy(..))
import           System.Directory (setPermissions, getPermissions, Permissions(..), canonicalizePath,
                                   getDirectoryContents, createDirectoryIfMissing, removeFile,
                                   doesFileExist)
import           System.IO (stderr, stdout)
import qualified Data.ByteString.Char8 as CBS
import qualified Data.Text as T

import           System.IO.Extra (withTempDir)
import           Control.Exception.Extra (try_)

import           System.IO.Silently (hCapture_)

import           Data.Aeson (decodeStrict, Value)

import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.HUnit (testCase, (@=?), assertFailure, assertBool)

import           Jupyter.Install.Internal as I
import           Utils (shouldThrow, inTempDir)

installTests :: TestTree
installTests = testGroup "Install Tests"
                 [ testVersionNumberParsing
                 , testVersionNumberPrinting
                 , testFindingJupyterExecutable
                 , testJupyterVersionReading
                 , testStderrIsUntouched
                 , testCorrectJupyterVersionsAccepted
                 , testKernelspecFilesCreated
                 , testEndToEndInstall
                 ]

-- Test that version numbers from jupyter --version are properly parsed.
testVersionNumberParsing :: TestTree
testVersionNumberParsing = testCase "Version number parsing" $ do
  Just (I.JupyterVersion 10 1 0) @=? I.parseVersion "10.1.0"
  Just (I.JupyterVersion 4 1 2000) @=? I.parseVersion "4.1.2000"
  Just (I.JupyterVersion 4 1 0) @=? I.parseVersion "4.1"
  Just (I.JupyterVersion 4 0 0) @=? I.parseVersion "4"
  Nothing @=? I.parseVersion ".xx.4"
  Nothing @=? I.parseVersion "4.1.2.1.2"

-- Test that version numbers from jupyter --version are properly printed to the user.
testVersionNumberPrinting :: TestTree
testVersionNumberPrinting = testCase "Version number printing" $ do
  parseThenShow "10.1.0"
  parseThenShow "4.1.200"
  parseThenShow "4.1.0"
  where
    parseThenShow str =
      Just str @=? (I.showVersion <$> I.parseVersion str)

-- Test that `jupyter` is found by `which` if it is on the PATH, and isn't found if its not on the
-- path or isn't executable. Ensures that all returned paths are absolute and canonical.
testFindingJupyterExecutable :: TestTree
testFindingJupyterExecutable = testCase "PATH searching" $
  -- Run the entire test in a temporary directory.
  inTempDir $ \tmp -> do
    -- Set up a PATH that has both relative and absolute paths.
    setEnv "PATH" $ ".:test-path/twice:" ++ tmp ++ "/test-path-2"

    -- For each possible location test executable finding.
    forM_ [".", "test-path/twice", "test-path-2"] $ \prefix -> do
      let path = prefix ++ "/jupyter"
      createDirectoryIfMissing True prefix

      -- When the file doesn't exist it should not be found.
      which "jupyter" `shouldThrow` (Proxy :: Proxy InstallException)

      -- When the file is not executable it should not be found.
      writeFile path "#!/bin/bash\ntrue"
      which "jupyter" `shouldThrow` (Proxy :: Proxy InstallException)

      -- When the file is executable, it should be found, and be an absolute path
      -- that ultimately resolves to what we expect.
      setExecutable path
      jupyterLoc <- which "jupyter"
      expectedLoc <- canonicalizePath $ tmp ++ "/" ++ prefix ++ "/jupyter"
      expectedLoc @=? jupyterLoc

      -- Clean up to avoid messing with future tests.
      removeFile path

testJupyterVersionReading :: TestTree
testJupyterVersionReading = testCase "jupyter --version parsing" $
  inTempDir $ \tmp -> do
    -- Set up a jupyter executable that outputs what we expect.
    setEnv "PATH" "."
    writeMockJupyter ""
    setExecutable "jupyter"
    path <- which "jupyter"

    -- Version too low.
    writeMockJupyter "1.2.0"
    verifyJupyterCommand path `shouldThrow` (Proxy :: Proxy InstallException)

    -- Could not parse output.
    writeMockJupyter "..."
    verifyJupyterCommand path `shouldThrow` (Proxy :: Proxy InstallException)

    writeMockJupyter "asdf"
    verifyJupyterCommand path `shouldThrow` (Proxy :: Proxy InstallException)

    -- Works.
    writeMockJupyter "3.0.0"
    verifyJupyterCommand path

    writeMockJupyter "4.1.4000"
    verifyJupyterCommand path

writeMockJupyter :: String -> IO ()
writeMockJupyter out = writeMockJupyter' out "" 0

writeMockJupyter' :: String -> String -> Int -> IO ()
writeMockJupyter' stdoutOut stderrOut errCode =
  writeFile "jupyter" $
    unlines
      [ "#!/bin/bash"
      , "echo -n \"" ++ stdoutOut ++ "\""
      , "echo -n \"" ++ stderrOut ++ "\" >/dev/stderr"
      , "exit " ++ show errCode
      ]

testStderrIsUntouched :: TestTree
testStderrIsUntouched = testCase "stderr is piped through" $
  inTempDir $ \tmp -> do
    -- Set up a jupyter executable that outputs something to stderr.
    setEnv "PATH" "."
    let msg = "An error"
    writeMockJupyter' "Some output" msg 0
    setExecutable "jupyter"

    -- Check that stderr goes through as usual.
    stderrOut <- hCapture_ [stderr] (runJupyterCommand "jupyter" [])
    msg @=? stderrOut

    -- Check that stdout of the command is not output but is captured.
    writeMockJupyter' "stdout" "" 0
    stdoutOut <- hCapture_ [stdout] (runJupyterCommand "jupyter" [])
    "" @=? stdoutOut

testCorrectJupyterVersionsAccepted :: TestTree
testCorrectJupyterVersionsAccepted = testCase "Correct jupyter versions accepted" $ do
  assertBool "Version 3 supported" $ jupyterVersionSupported $ JupyterVersion 3 0 0
  assertBool "Version 3.1 supported" $ jupyterVersionSupported $ JupyterVersion 3 1 0
  assertBool "Version 4 supported" $ jupyterVersionSupported $ JupyterVersion 4 0 0
  assertBool "Version 10 supported" $ jupyterVersionSupported $ JupyterVersion 10 0 0
  assertBool "Version 2.3 not supported" $ not $ jupyterVersionSupported $ JupyterVersion 2 3 0
  assertBool "Version 1.0 not supported" $ not $ jupyterVersionSupported $ JupyterVersion 1 0 0

testKernelspecFilesCreated :: TestTree
testKernelspecFilesCreated = testCase "kernelspec files created" $
  inTempDir $ \tmp -> do
    kernelspec <- createTestKernelspec tmp

    -- Test that all required files are created
    withTempDir $ \kernelspecDir -> do
      prepareKernelspecDirectory kernelspec kernelspecDir
      assertBool "kernel.js not copied" =<< doesFileExist (kernelspecDir ++ "/kernel.js")
      assertBool "logo-64x64.png not copied" =<< doesFileExist (kernelspecDir ++ "/logo-64x64.png")
      assertBool "kernel.json not created" =<< doesFileExist (kernelspecDir ++ "/kernel.json")

    -- Test that the file is valid JSON and {connection_file} is present.
    withTempDir $ \kernelspecDir -> do
      prepareKernelspecDirectory kernelspec kernelspecDir
      kernelJson <- readFile (kernelspecDir ++ "/kernel.json")
      assertBool "{connection_file} not found" $ "\"{connection_file}\"" `isInfixOf` kernelJson

      case decodeStrict (CBS.pack kernelJson) :: Maybe Value of
        Nothing -> assertFailure "Could not decode kernel.json file as JSON"
        Just _  -> return ()


    -- Test that all previously-existing files are gone
    withTempDir $ \kernelspecDir -> do
      let prevFile1 = kernelspecDir ++ "/tmp.file"
          prevFile2 = kernelspecDir ++ "/kernel.js"
      writeFile prevFile1 "test1"
      writeFile prevFile2 "test2"

      prepareKernelspecDirectory kernelspec { kernelspecJsFile = Nothing } kernelspecDir

      assertBool "previous file still exists" =<< fmap not (doesFileExist prevFile1)
      assertBool "previous kernel.js file still exists" =<< fmap not (doesFileExist prevFile2)

-- Test that end-to-end installs work as expected, and call the 'jupyter kernelspec install'
-- in the way that they are expected to.
testEndToEndInstall :: TestTree
testEndToEndInstall = testCase "installs end-to-end" $
  inTempDir $ \tmp -> do
    kernelspec <- createTestKernelspec tmp

    setEnv "PATH" "."
    writeFile "jupyter" $ jupyterScript True
    setExecutable "jupyter"

    result <- installKernel InstallLocal kernelspec
    case result of
      InstallFailed msg -> assertFailure $ "Failed to install kernelspec: " ++ T.unpack msg
      _                 -> return ()

    writeFile "jupyter" $ jupyterScript False
    result <- installKernel InstallGlobal kernelspec
    case result of
      InstallFailed msg -> assertFailure $ "Failed to install kernelspec: " ++ T.unpack msg
      _                 -> return ()
  where
    jupyterScript user =
      unlines
        [ "#!/bin/bash"
        , "if [[ $1 == \"--version\" ]]; then"
        , "echo 4.1.0"
        , "else"
        , "[[ \"$1 $2 $4\" == \"kernelspec install --replace\" ]] || exit 1"
        , if user
            then "[[ \"$5\" == \"--user\" ]] || exit 0"
            else ""
        , "fi"
        ]

-- Create a kernelspec that refers to newly generated files in the provided directory.
createTestKernelspec :: String -> IO Kernelspec
createTestKernelspec tmp = do
  let kernelJsFile = tmp ++ "/" ++ "kernel.js"
  writeFile kernelJsFile "kernel.js"

  let kernelLogoFile = tmp ++ "/" ++ "logo-64x64.png"
  writeFile kernelLogoFile "logo-64x64.png"

  return
    Kernelspec
      { kernelspecDisplayName = "Test"
      , kernelspecLanguage = "test"
      , kernelspecCommand = \conn -> ["test", conn, "--test"]
      , kernelspecJsFile = Just kernelJsFile
      , kernelspecLogoFile = Just kernelLogoFile
      , kernelspecEnv = mempty
      }

-- Make a file executable.
setExecutable :: FilePath -> IO ()
setExecutable path = do
  perms <- getPermissions path
  setPermissions path perms { executable = True }
