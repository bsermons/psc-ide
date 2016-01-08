{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PackageImports #-}

module PureScript.Ide where


import           Control.Monad.Except
import           Control.Monad.Reader.Class
import           Control.Monad.Trans.Either
import           "monad-logger" Control.Monad.Logger
import qualified Data.Map.Lazy            as M
import           Data.Maybe               (mapMaybe, catMaybes)
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text  as T
import           PureScript.Ide.Completion
import           PureScript.Ide.Externs
import           PureScript.Ide.Pursuit
import           PureScript.Ide.Error
import           PureScript.Ide.Types
import           PureScript.Ide.SourceFile
import           PureScript.Ide.State
import           PureScript.Ide.Reexports
import qualified PureScript.Ide.CaseSplit as CS
import           System.FilePath
import           System.Directory

findCompletions :: (PscIde m, MonadLogger m) =>
                   [Filter] -> Matcher -> m Success
findCompletions filters matcher =
  CompletionResult . getCompletions filters matcher <$> getAllModulesWithReexports

findType :: (PscIde m, MonadLogger m) =>
            DeclIdent -> [Filter] -> m Success
findType search filters =
  CompletionResult . getExactMatches search filters <$> getAllModulesWithReexports

findPursuitCompletions :: (MonadIO m, MonadLogger m) =>
                          PursuitQuery -> m Success
findPursuitCompletions (PursuitQuery q) =
  PursuitResult <$> liftIO (searchPursuitForDeclarations q)

findPursuitPackages :: (MonadIO m, MonadLogger m) =>
                       PursuitQuery -> m Success
findPursuitPackages (PursuitQuery q) =
  PursuitResult <$> liftIO (findPackagesForModuleIdent q)

loadExtern ::(PscIde m, MonadLogger m) =>
             FilePath -> m (Either Error ())
loadExtern fp = runEitherT $ do
  m <- EitherT . liftIO $ readExternFile fp
  lift (insertModule m)

printModules :: (PscIde m) => m Success
printModules = printModules' <$> getPscIdeState

printModules' :: M.Map ModuleIdent [ExternDecl] -> Success
printModules' = ModuleList . M.keys

listAvailableModules :: PscIde m => m Success
listAvailableModules = do
  outputPath <- confOutputPath . envConfiguration <$> ask
  liftIO $ do
    cwd <- getCurrentDirectory
    dirs <- getDirectoryContents (cwd </> outputPath)
    return (ModuleList (listAvailableModules' dirs))

listAvailableModules' :: [FilePath] -> [Text]
listAvailableModules' dirs =
  let cleanedModules = filter (`notElem` [".", ".."]) dirs
  in map T.pack cleanedModules

caseSplit :: (PscIde m, MonadLogger m) =>
  Text -> Int -> Int -> Text -> m Success
caseSplit l b e t = do
  patterns <- CS.makePattern l b e <$> CS.caseSplit t
  pure (MultilineTextResult patterns)

importsForFile :: (MonadIO m, MonadLogger m) =>
                  FilePath -> m (Either Error Success)
importsForFile fp = do
  imports <- liftIO (getImportsForFile fp)
  return (ImportList <$> imports)

-- | The first argument is a set of modules to load. The second argument
--   denotes modules for which to load dependencies
loadModulesAndDeps :: (PscIde m, MonadLogger m) =>
                     [ModuleIdent] -> [ModuleIdent] -> m (Either Error Success)
loadModulesAndDeps mods deps = do
  r1 <- mapM loadModule (mods ++ deps)
  r2 <- mapM loadModuleDependencies deps
  return $ do
    moduleResults <- fmap T.concat (sequence r1)
    dependencyResults <- fmap T.concat (sequence r2)
    return (TextResult (moduleResults <> ", " <> dependencyResults))

loadModuleDependencies ::(PscIde m, MonadLogger m) =>
                         ModuleIdent -> m (Either Error Text)
loadModuleDependencies moduleName = do
  m <- getModule moduleName
  case getDependenciesForModule <$> m of
    Just deps -> do
      mapM_ loadModule deps
      -- We need to load the modules, that get reexported from the dependencies
      depModules <- catMaybes <$> mapM getModule deps
      -- What to do with errors here? This basically means a reexported dependency
      -- doesn't exist in the output/ folder
      _ <- traverse loadReexports depModules
      return (Right ("Dependencies for " <> moduleName <> " loaded."))
    Nothing -> return (Left (ModuleNotFound moduleName))

loadReexports :: (PscIde m, MonadLogger m) =>
                Module -> m (Either Error [ModuleIdent])
loadReexports m = case getReexports m of
  [] -> return (Right [])
  exportDeps -> runEitherT $ do
    -- I'm fine with this crashing on a failed pattern match.
    -- If this ever fails I'll need to look at GADTs
    let reexports = map (\(Export mn) -> mn) exportDeps
    lift $ $(logDebug) ("Loading reexports for module: " <> fst m <>
                        " reexports: " <> T.concat reexports)
    _ <- traverse (EitherT . loadModule) reexports
    exportDepsModules <- lift $ catMaybes <$> traverse getModule reexports
    exportDepDeps <- traverse (EitherT . loadReexports) exportDepsModules
    return $ concat exportDepDeps

getDependenciesForModule :: Module -> [ModuleIdent]
getDependenciesForModule (_, decls) = mapMaybe getDependencyName decls
  where getDependencyName (Dependency dependencyName _) = Just dependencyName
        getDependencyName _ = Nothing

loadModule :: (PscIde m, MonadLogger m) =>
              ModuleIdent -> m (Either Error Text)
loadModule mn = runEitherT $ do
  path <- EitherT (filePathFromModule mn)
  EitherT (loadExtern path)
  lift $ $(logDebug) ("Loaded extern file at: " <> T.pack path)
  return ("Loaded extern file at: " <> T.pack path)

filePathFromModule :: PscIde m => ModuleIdent -> m (Either Error FilePath)
filePathFromModule moduleName = do
  outputPath <- confOutputPath . envConfiguration <$> ask
  liftIO $ do
    cwd <- liftIO getCurrentDirectory
    let path = cwd </> outputPath </> T.unpack moduleName </> "externs.json"
    ex <- liftIO $ doesFileExist path
    return $
      if ex
      then Right path
      else Left (ModuleFileNotFound moduleName)

-- | Taken from Data.Either.Utils
maybeToEither :: MonadError e m =>
                 e                      -- ^ (Left e) will be returned if the Maybe value is Nothing
              -> Maybe a                -- ^ (Right a) will be returned if this is (Just a)
              -> m a
maybeToEither errorval Nothing = throwError errorval
maybeToEither _ (Just normalval) = return normalval
