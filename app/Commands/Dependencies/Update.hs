module Commands.Dependencies.Update where

import Commands.Base
import Juvix.Compiler.Pipeline.Loader.PathResolver
import Juvix.Compiler.Pipeline.Setup

runCommand :: (Members '[Embed IO, TaggedLock, App] r) => Sem r ()
runCommand = runPipelineSetup (entrySetup (set dependenciesConfigForceUpdateLockfile True defaultDependenciesConfig))
