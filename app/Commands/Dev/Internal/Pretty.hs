module Commands.Dev.Internal.Pretty where

import Commands.Base
import Commands.Dev.Internal.Pretty.Options
import Juvix.Compiler.Internal.Pretty qualified as Internal
import Juvix.Compiler.Internal.Translation.FromConcrete qualified as Internal

runCommand :: (Members '[Embed IO, App, TaggedLock] r) => InternalPrettyOptions -> Sem r ()
runCommand opts = do
  globalOpts <- askGlobalOptions
  intern <- (^. pipelineResult . Internal.resultModule) <$> runPipelineTermination (opts ^. internalPrettyInputFile) upToInternal
  renderStdOut (Internal.ppOut globalOpts intern)
