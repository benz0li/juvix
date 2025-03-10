module Commands.Dev.Nockma.Eval where

import Commands.Base hiding (Atom)
import Commands.Dev.Nockma.Eval.Options
import Juvix.Compiler.Nockma.EvalCompiled
import Juvix.Compiler.Nockma.Evaluator.Options
import Juvix.Compiler.Nockma.Pretty
import Juvix.Compiler.Nockma.Translation.FromAsm
import Juvix.Compiler.Nockma.Translation.FromSource qualified as Nockma

runCommand :: forall r. (Members '[Embed IO, App] r) => NockmaEvalOptions -> Sem r ()
runCommand opts = do
  afile <- fromAppPathFile file
  parsedTerm <- Nockma.parseTermFile (toFilePath afile)
  case parsedTerm of
    Left err -> exitJuvixError (JuvixError err)
    Right (TermCell c) -> do
      res <-
        runReader defaultEvalOptions
          . runOutputSem @(Term Natural) (say . ppTrace)
          $ evalCompiledNock' (c ^. cellLeft) (c ^. cellRight)
      ret <- getReturn res
      putStrLn (ppPrint ret)
    Right TermAtom {} -> exitFailMsg "Expected nockma input to be a cell"
  where
    file :: AppPath File
    file = opts ^. nockmaEvalFile

    getReturn :: Term Natural -> Sem r (Term Natural)
    getReturn res =
      let valStack = getStack ValueStack res
       in case valStack of
            TermCell c -> return (c ^. cellLeft)
            TermAtom {} -> exitFailMsg "Program does not return a value"
