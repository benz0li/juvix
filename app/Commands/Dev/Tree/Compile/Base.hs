module Commands.Dev.Tree.Compile.Base where

import Commands.Base
import Commands.Dev.Tree.Compile.Options
import Commands.Extra.Compile qualified as Compile
import Juvix.Compiler.Asm.Pretty qualified as Asm
import Juvix.Compiler.Backend qualified as Backend
import Juvix.Compiler.Backend.C qualified as C
import Juvix.Compiler.Nockma.Pretty qualified as Nockma
import Juvix.Compiler.Tree.Data.InfoTable qualified as Tree

data PipelineArg = PipelineArg
  { _pipelineArgOptions :: CompileOptions,
    _pipelineArgFile :: Path Abs File,
    _pipelineArgTable :: Tree.InfoTable
  }

getEntry :: (Members '[Embed IO, App, TaggedLock] r) => PipelineArg -> Sem r EntryPoint
getEntry PipelineArg {..} = do
  ep <- getEntryPoint (AppPath (preFileFromAbs _pipelineArgFile) True)
  return $
    ep
      { _entryPointTarget = getTarget (_pipelineArgOptions ^. compileTarget),
        _entryPointDebug = _pipelineArgOptions ^. compileDebug,
        _entryPointUnsafe = _pipelineArgOptions ^. compileUnsafe,
        _entryPointOptimizationLevel = fromMaybe defaultOptLevel (_pipelineArgOptions ^. compileOptimizationLevel),
        _entryPointInliningDepth = _pipelineArgOptions ^. compileInliningDepth
      }
  where
    getTarget :: CompileTarget -> Backend.Target
    getTarget = \case
      TargetWasm32Wasi -> Backend.TargetCWasm32Wasi
      TargetNative64 -> Backend.TargetCNative64
      TargetGeb -> Backend.TargetGeb
      TargetVampIR -> Backend.TargetVampIR
      TargetCore -> Backend.TargetCore
      TargetAsm -> Backend.TargetAsm
      TargetTree -> Backend.TargetTree
      TargetNockma -> Backend.TargetNockma

    defaultOptLevel :: Int
    defaultOptLevel
      | _pipelineArgOptions ^. compileDebug = 0
      | otherwise = defaultOptimizationLevel

runCPipeline ::
  forall r.
  (Members '[Embed IO, App, TaggedLock] r) =>
  PipelineArg ->
  Sem r ()
runCPipeline pa@PipelineArg {..} = do
  entryPoint <- getEntry pa
  C.MiniCResult {..} <-
    getRight
      . run
      . runReader entryPoint
      . runError @JuvixError
      $ treeToMiniC _pipelineArgTable
  cFile <- inputCFile _pipelineArgFile
  embed @IO $ writeFileEnsureLn cFile _resultCCode
  outfile <- Compile.outputFile _pipelineArgOptions _pipelineArgFile
  Compile.runCommand
    _pipelineArgOptions
      { _compileInputFile = Just (AppPath (preFileFromAbs cFile) False),
        _compileOutputFile = Just (AppPath (preFileFromAbs outfile) False)
      }
  where
    inputCFile :: Path Abs File -> Sem r (Path Abs File)
    inputCFile inputFileCompile = do
      buildDir <- askBuildDir
      ensureDir buildDir
      return (buildDir <//> replaceExtension' ".c" (filename inputFileCompile))

runAsmPipeline :: (Members '[Embed IO, App, TaggedLock] r) => PipelineArg -> Sem r ()
runAsmPipeline pa@PipelineArg {..} = do
  entryPoint <- getEntry pa
  asmFile <- Compile.outputFile _pipelineArgOptions _pipelineArgFile
  r <-
    runReader entryPoint
      . runError @JuvixError
      . treeToAsm
      $ _pipelineArgTable
  tab' <- getRight r
  let code = Asm.ppPrint tab' tab'
  embed @IO $ writeFileEnsureLn asmFile code

runNockmaPipeline :: (Members '[Embed IO, App, TaggedLock] r) => PipelineArg -> Sem r ()
runNockmaPipeline pa@PipelineArg {..} = do
  entryPoint <- getEntry pa
  nockmaFile <- Compile.outputFile _pipelineArgOptions _pipelineArgFile
  r <-
    runReader entryPoint
      . runError @JuvixError
      . treeToNockma
      $ _pipelineArgTable
  tab' <- getRight r
  let code = Nockma.ppSerialize tab'
  embed @IO $ writeFileEnsureLn nockmaFile code
