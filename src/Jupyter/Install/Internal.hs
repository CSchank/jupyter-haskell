{-|
Module      : Jupyter.Install.Internal
Description : Utilities for installing Jupyter kernels (internal implementation).
Copyright   : (c) Andrew Gibiansky, 2016
License     : MIT
Maintainer  : andrew.gibiansky@gmail.com
Stability   : stable
Portability : POSIX

This module exposes the internal implementation for "Jupyter.Install".
For user-facing documentation, please check out "Jupyter.Install" instead.
-}

{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Jupyter.Install.Internal where

import           Control.Monad (forM_, void, unless, when, foldM)
import           Data.Maybe (isJust, listToMaybe)
import           System.Environment (getExecutablePath)
import           System.Directory (findExecutable, getTemporaryDirectory, removeDirectoryRecursive,
                                   createDirectoryIfMissing, copyFile, doesDirectoryExist,
                                   canonicalizePath, doesFileExist)
import           System.Process (readProcess)
import           System.IO (withFile, IOMode(..))
import           Text.Read (readMaybe)
import           Control.Exception (Exception, IOException, catch, throwIO)
import qualified Data.HashMap.Lazy as HashMap
import qualified Data.Map as Map

import           Data.Aeson ((.=), object, encode, eitherDecode, FromJSON(..), Value(..), (.:))
import           Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as CBS
import qualified Data.Text as T
import           Data.Text (Text)
import           Data.Map (Map)

-- | A /kernelspec/ is a description of a kernel which tells the Jupyter command-line application how to install
-- the kernel and tells the frontends how to invoke the kernel (command line flags, environment, etc).
--
-- More documentation about kernelspecs is located in the <http://jupyter-client.readthedocs.io/en/latest/kernels.html#kernelspecs official documentation>.
data Kernelspec =
       Kernelspec
         { kernelspecDisplayName :: Text -- ^ Name for the kernel to be shown in frontends, e.g. \"Haskell\".
         , kernelspecLanguage :: Text    -- ^ Language name for the kernel, used to refer to this kernel (in command-line arguments, URLs, etc), e.g. "haskell".
         , kernelspecCommand :: FilePath -> FilePath -> [String] -- ^ How to invoke the kernel. Given the path to the currently running executable and connection file, this function
            -- should return the full command to invoke the kernel. Example:
         --
         -- > \exe connectionFile -> [exe, "kernel", "--debug", "--connection-file", connectionFile]
         , kernelspecJsFile :: Maybe FilePath -- ^ (optional) path to a Javascript file (kernel.js) to provide to the Jupyter notebook.
         -- This file is loaded upon notebook startup.
         , kernelspecLogoFile :: Maybe FilePath -- ^ (optional) path to a 64x64 PNG file to display as the kernel logo in the notebook.
         , kernelspecEnv :: Map Text Text -- ^ Additional environment variables to set when invoking the kernel. If no additional
         -- environment variables are required, pass @'Data.Map.fromList' []@ or 'Data.Monoid.mempty'.
         }

-- | Whether the installation was successful.
data InstallResult = InstallSuccessful       -- ^ Kernelspec installation was successful.
                   | InstallFailed Text      -- ^ Kernelspec installation failed, with the reason for failure provided.
  deriving (Eq, Ord, Show)

-- | Whether to install the kernel globally or just for the current user.
--
-- This corresponds to the @--user@ flag for @jupyter kernelspec install@. 
data InstallUser = InstallLocal   -- ^ Install this kernel just for this user.
                 | InstallGlobal  -- ^ Install this kernel globally.
  deriving (Eq, Ord, Show)

-- | An exception type for expected exceptions during installation.
newtype JupyterException = JupyterException Text
  deriving (Eq, Ord, Show)

-- | 'JupyterException's can be thrown when an expected installation failure occurs.
instance Exception JupyterException

-- | Version of Jupyter currently running, detected by running @jupyter --version@.
--
-- When a version number is not present it is assumed to be zero, so 4.1 equivalent to 4.1.0.
data JupyterVersion =
       JupyterVersion
         { versionMajor :: Int -- ^ Major version number.
         , versionMinor :: Int -- ^ Minor version number.
         , versionPatch :: Int -- ^ Patch version number.
         }
  deriving (Eq, Ord, Show)

-- | Convert a 'JupyterVersion' to its original displayed form.
--
-- >>> showVersion (JupyterVersion 4 1 1)
-- "4.1.1"
showVersion :: JupyterVersion -> String
showVersion (JupyterVersion major minor patch) =
  concat [show major, ".", show minor, ".", show patch]

-- | Install a 'Kernelspec' using @jupyter kernelspec install@.
--
-- This function expects the @jupyter@ command to be on the user's PATH, and will fail if
-- the @jupyter@ command is either unavailable or is a version incompatible with this library.
--
-- More documentation about kernelspecs is located in the <TODO Jupyter documentation> and by running @jupyter kernelspec install --help@.
installKernel :: InstallUser -- ^ Whether the kernel should be installed for only the current user (with --user) or globally
              -> Kernelspec  -- ^ The kernelspec to install
              -> IO InstallResult -- ^ Installation result, potentially with a friendly error message
installKernel installUser kernelspec = tryInstall `catch` handleInstallFailure
  where
    tryInstall :: IO InstallResult
    tryInstall = do
      jupyterPath <- which "jupyter"
      verifyJupyterCommand jupyterPath
      installKernelspec installUser jupyterPath kernelspec
      return InstallSuccessful

    handleInstallFailure :: JupyterException -> IO InstallResult
    handleInstallFailure (JupyterException message) = return $ InstallFailed message

-- | Throw a 'JupyterException' with a given error message.
installFailed :: String -> IO a
installFailed = throwIO . JupyterException . T.pack

-- | Determine the absolute path to an executable on the PATH.
--
-- Throws a 'JupyterException' if the the executable cannot be found.
which :: FilePath -> IO FilePath
which cmd = do
  mPath <- findExecutable cmd
  case mPath of
    Just path -> canonicalizePath path
    Nothing ->
      installFailed $ "Could not find '" ++
                      cmd ++
                      "' command on system PATH; please install it."

-- | Verify that a proper version of Jupyter is installed.
--
-- Throws a 'JupyterException' if @jupyter@ is not present, is an incompatible version, or
-- otherwise cannot be used with this library.
verifyJupyterCommand :: FilePath -> IO ()
verifyJupyterCommand jupyterPath = do
  versionInfo <- runJupyterCommand jupyterPath ["--version"]
  case parseVersion versionInfo of
    Nothing -> installFailed $ "Could not parse output of 'jupyter --version': " ++ versionInfo
    Just jupyterVersion ->
      unless (jupyterVersionSupported jupyterVersion) $
        installFailed $
          "Invalid Jupyter version: Jupyter version 3.0 or higher required, found "
          ++ showVersion jupyterVersion

-- | Run a @jupyter@ subcommand with no standard input.
--
-- Throws a 'JupyterException' if the command cannot be run or returns a non-zero exit code.
runJupyterCommand :: FilePath -> [String] -> IO String
runJupyterCommand jupyterPath args = readProcess jupyterPath args "" `catch` handler
  where
    handler :: IOException -> IO String
    handler _ =
      installFailed $
        concat
          [ "Could not run '"
          , jupyterPath
          , " "
          , unwords args
          , "'. "
          , "Please make sure Jupyter is installed and functional."
          ]

-- | Is this Jupyter version supported?
jupyterVersionSupported :: JupyterVersion -> Bool
jupyterVersionSupported JupyterVersion{..} = versionMajor >= 3

-- | Given a directory, populate it with all necessary files to run @jupyter kernelspec install@.
--
-- Currently created files include:
--  * @kernel.js@: (optional) Javascript to include in the notebook frontend.
--  * @logo-64x64.png@: (optional) Small logo PNG to include in the notebook frontend UI.
--  * @kernel.json@: (required) JSON file containing kernel invocation command and other metadata.
--
-- The passed in directory is created and should not exist; if it already exists, it will be
-- deleted.
prepareKernelspecDirectory :: Kernelspec -> FilePath -> IO ()
prepareKernelspecDirectory kernelspec dir = do
  -- Make sure the directory doesn't already exist. If we didn't delete the directory, then later
  -- kernelspec installs may inherit files created by previous kernelspec installs.
  exists <- doesDirectoryExist dir
  when exists $ removeDirectoryRecursive dir

  createDirectoryIfMissing True dir
  copyKernelspecFiles kernelspec
  generateKernelJSON kernelspec

  where
    -- Copy files indicated by the Kernelspec data type into the directory.
    copyKernelspecFiles :: Kernelspec -> IO ()
    copyKernelspecFiles Kernelspec { .. } = do
      forM_ kernelspecJsFile $ \file -> copyFile file $ dir ++ "/kernel.js"
      forM_ kernelspecLogoFile $ \file -> copyFile file $ dir ++ "/logo-64x64.png"

    -- Generate the kernel.json data structure from the Kernelspec datatype.
    generateKernelJSON :: Kernelspec -> IO ()
    generateKernelJSON Kernelspec { .. } = do
      exePath <- getExecutablePath
      withFile (dir ++ "/kernel.json") WriteMode $
        flip LBS.hPutStr $
          encode $
            object
              [ "argv" .= kernelspecCommand exePath "{connection_file}"
              , "display_name" .= kernelspecDisplayName
              , "language" .= kernelspecLanguage
              , "env" .= kernelspecEnv
              ]

-- | Install a kernelspec using @jupyter kernelspec install@.
--
-- Throws a 'JupyterException' on failure.
installKernelspec :: InstallUser -- ^ Whether this kernel should be installed with or without --user 
                  -> FilePath    -- ^ Path to the @jupyter@ executable
                  -> Kernelspec  -- ^ Kernelspec to install
                  -> IO ()
installKernelspec installUser jupyterPath kernelspec = do
  tempDir <- getTemporaryDirectory
  let kernelspecDir = tempDir ++ "/" ++ T.unpack (kernelspecLanguage kernelspec)
  prepareKernelspecDirectory kernelspec kernelspecDir

  let userFlag =
        case installUser of
          InstallLocal  -> ["--user"]
          InstallGlobal -> []
      cmd = "kernelspec" : "install" : kernelspecDir : "--replace" : userFlag
  void $ runJupyterCommand jupyterPath cmd


-- | Parse a Jupyter version string into a list of integers.
--
-- >>> parseVersion "4.1.3\n"
-- Just (JupyterVersion 4 1 3)
--
-- >>> parseVersion "XYZ"
-- Nothing
--
-- If minor or patch versions are unavailable, they are assumed to be zero:
--
-- >>> parseVersion "4.1"
-- Just (JupyterVersion 4 1 0)
--
-- >>> parseVersion "4"
-- Just (JupyterVersion 4 0 0)
parseVersion :: String -> Maybe JupyterVersion
parseVersion versionStr =
  let versions = map (readMaybe . T.unpack) $ T.splitOn "." $ T.pack versionStr
      parsed = all isJust versions
  in if parsed
       then case versions of
         [x, y, z] -> JupyterVersion <$> x <*> y <*> z
         [x, y]    -> JupyterVersion <$> x <*> y <*> pure 0
         [x]       -> JupyterVersion <$> x <*> pure 0 <*> pure 0
         _         -> Nothing
       else Nothing

-- | Find the kernelspec for a kernel with a given language name.
--
-- If no such kernel exists, then 'Nothing' is returned. If an error occurs
-- while searching for Jupyter kernels, a 'JupyterException' is thrown.
findKernel :: Text -> IO (Maybe Kernelspec)
findKernel language = 
  listToMaybe . filter ((language ==) . kernelspecLanguage) <$> findKernels

-- | Find all kernelspecs that the Jupyter installation is aware of,
-- using the @jupyter kernelspec list@ command.
--
-- If an error occurs while searching for Jupyter kernels, a 'JupyterException' is thrown.
findKernels :: IO [Kernelspec]
findKernels = do
  jupyterPath <- which "jupyter"
  specs <- eitherDecode . CBS.pack <$> runJupyterCommand jupyterPath ["kernelspec", "list", "--json"]
  case specs of
    Left err -> throwIO $ JupyterException $ T.pack err
    Right (Kernelspecs kernelspecs) -> mapM checkKernelspecFiles $ Map.elems kernelspecs


-- | Kernelspecs can refer to files such as kernel.js and logo-64x64.png. Check whether the
-- kernelspec refers to that file; if it does, check that the file exists. If the file doesn't
-- exist, then remove it from the kernelspec.
checkKernelspecFiles :: Kernelspec -> IO Kernelspec
checkKernelspecFiles Kernelspec { .. } = do
  let jsFile = kernelspecJsFile
      logoFile = kernelspecLogoFile
  kernelspecJsFile <- checkFile jsFile
  kernelspecLogoFile <- checkFile logoFile
  return Kernelspec { .. }

  where
    checkFile :: Maybe FilePath -> IO (Maybe FilePath)
    checkFile Nothing = return Nothing
    checkFile (Just file) = do
      exists <- doesFileExist file
      return $ if exists
                 then Just file
                 else Nothing

newtype Kernelspecs = Kernelspecs (Map Text Kernelspec)

instance FromJSON Kernelspecs where
  parseJSON (Object outer) = do
    inner <- outer .: "kernelspecs"
    case inner of
      Object innerObj ->
        let items = HashMap.toList innerObj
        in Kernelspecs <$> foldM accumKernelspecs mempty items
      _ -> fail "Expecting object inside 'kernelspecs' key"
  parseJSON _ = fail "Expecting object with 'kernelspecs' key"

accumKernelspecs :: Map Text Kernelspec -> (Text, Value) -> Parser (Map Text Kernelspec)
accumKernelspecs prev (name, val) = do
  kernelspec <- parseKernelspec val
  return $ Map.insert name kernelspec prev

parseKernelspec :: Value -> Parser Kernelspec
parseKernelspec v =
  case v of
    Object o -> do
      dir <- o .: "resource_dir"
      spec <- o .: "spec"
      Kernelspec <$> spec .: "display_name"
                 <*> spec .: "language"
                 <*> (createCommand <$> spec .: "argv")
                 <*> pure (Just $ dir ++ "/kernel.js")
                 <*> pure (Just $ dir ++ "/logo-64x64.png")
                 <*> spec .: "env"
    _ -> fail "Expecting object for kernelspec"
  where
    createCommand :: [Text] -> FilePath -> FilePath -> [String]
    createCommand argv exec0 connFile =
      flip map argv $ \val ->
        case val of
          "{connection_file}" -> connFile
          _ -> T.unpack val

