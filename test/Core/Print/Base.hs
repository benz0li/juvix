module Core.Print.Base where

import Base
import Core.Eval.Base
import Core.Eval.Positive qualified as Eval
import Juvix.Compiler.Core.Data.Module (computeCombinedInfoTable, moduleFromInfoTable)
import Juvix.Compiler.Core.Pretty
import Juvix.Compiler.Core.Transformation.DisambiguateNames (disambiguateNames)
import Juvix.Compiler.Core.Translation.FromSource

newtype Test = Test
  { _testEval :: Eval.PosTest
  }

fromTest :: Test -> TestTree
fromTest = mkTest . toTestDescr

root :: Path Abs Dir
root = relToProject $(mkRelDir "tests/Core/positive/")

toTestDescr :: Test -> TestDescr
toTestDescr Test {..} =
  let Eval.PosTest {..} = _testEval
      tRoot = root <//> _relDir
      file' = tRoot <//> _file
      expected' = tRoot <//> _expectedFile
   in TestDescr
        { _testName = _name,
          _testRoot = tRoot,
          _testAssertion = Steps $ corePrintAssertion file' expected'
        }

corePrintAssertion ::
  Path Abs File ->
  Path Abs File ->
  (String -> IO ()) ->
  Assertion
corePrintAssertion mainFile expectedFile step = do
  step "Parse"
  r <- parseFile mainFile
  case r of
    Left err -> assertFailure (show (pretty err))
    Right (_, Nothing) -> do
      step "Empty program: compare expected and actual program output"
      expected <- readFile (toFilePath expectedFile)
      assertEqDiffText ("Check: EVAL output = " <> toFilePath expectedFile) "" expected
    Right (tabIni, Just node) -> do
      let m = disambiguateNames (moduleFromInfoTable $ setupMainFunction defaultModuleId tabIni node)
          tab = computeCombinedInfoTable m
      step "Print and parse back"
      let r' = runParserMain mainFile defaultModuleId mempty (ppPrint tab)
      case r' of
        Left err -> assertFailure (show (pretty err))
        Right tab' -> coreEvalAssertion' EvalModePlain tab' mainFile expectedFile step
