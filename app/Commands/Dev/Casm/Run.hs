module Commands.Dev.Casm.Run where

import Commands.Base
import Commands.Dev.Casm.Run.Options
import Juvix.Compiler.Casm.Interpreter qualified as Casm
import Juvix.Compiler.Casm.Translation.FromSource qualified as Casm
import Juvix.Compiler.Casm.Validate qualified as Casm

runCommand :: forall r. (Members '[Embed IO, App] r) => CasmRunOptions -> Sem r ()
runCommand opts = do
  afile :: Path Abs File <- fromAppPathFile file
  s <- readFile (toFilePath afile)
  case Casm.runParser (toFilePath afile) s of
    Left err -> exitJuvixError (JuvixError err)
    Right (labi, code) ->
      case Casm.validate labi code of
        Left err -> exitJuvixError (JuvixError err)
        Right () -> embed $ print (Casm.runCode labi code)
  where
    file :: AppPath File
    file = opts ^. casmRunInputFile
