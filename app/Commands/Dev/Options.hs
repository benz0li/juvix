module Commands.Dev.Options
  ( module Commands.Dev.Options,
    module Commands.Dev.Asm.Options,
    module Commands.Dev.Core.Options,
    module Commands.Dev.Geb.Options,
    module Commands.Dev.Internal.Options,
    module Commands.Dev.Parse.Options,
    module Commands.Dev.Highlight.Options,
    module Commands.Dev.Scope.Options,
    module Commands.Dev.Termination.Options,
    module Commands.Dev.DisplayRoot.Options,
  )
where

import Commands.Dev.Asm.Options hiding (Compile)
import Commands.Dev.Casm.Options
import Commands.Dev.Core.Options
import Commands.Dev.DisplayRoot.Options
import Commands.Dev.Geb.Options
import Commands.Dev.Highlight.Options
import Commands.Dev.Internal.Options
import Commands.Dev.MigrateJuvixYaml.Options
import Commands.Dev.Nockma.Options
import Commands.Dev.Parse.Options
import Commands.Dev.Repl.Options
import Commands.Dev.Runtime.Options
import Commands.Dev.Scope.Options
import Commands.Dev.Termination.Options
import Commands.Dev.Tree.Options
import Commands.Repl.Options
import CommonOptions

data DevCommand
  = DisplayRoot RootOptions
  | Highlight HighlightOptions
  | Internal InternalCommand
  | Core CoreCommand
  | Geb GebCommand
  | Asm AsmCommand
  | Tree TreeCommand
  | Casm CasmCommand
  | Runtime RuntimeCommand
  | Parse ParseOptions
  | Scope ScopeOptions
  | Termination TerminationCommand
  | JuvixDevRepl ReplOptions
  | MigrateJuvixYaml MigrateJuvixYamlOptions
  | Nockma NockmaCommand
  deriving stock (Data)

parseDevCommand :: Parser DevCommand
parseDevCommand =
  hsubparser
    ( mconcat
        [ commandHighlight,
          commandInternal,
          commandCore,
          commandGeb,
          commandAsm,
          commandTree,
          commandCasm,
          commandRuntime,
          commandParse,
          commandScope,
          commandShowRoot,
          commandTermination,
          commandJuvixDevRepl,
          commandMigrateJuvixYaml,
          commandNockma
        ]
    )

commandHighlight :: Mod CommandFields DevCommand
commandHighlight =
  command "highlight" $
    info
      (Highlight <$> parseHighlight)
      (progDesc "Highlight a Juvix file")

commandInternal :: Mod CommandFields DevCommand
commandInternal =
  command "internal" $
    info
      (Internal <$> parseInternalCommand)
      (progDesc "Subcommands related to Internal")

commandGeb :: Mod CommandFields DevCommand
commandGeb =
  command "geb" $
    info
      (Geb <$> parseGebCommand)
      (progDesc "Subcommands related to JuvixGeb")

commandCore :: Mod CommandFields DevCommand
commandCore =
  command "core" $
    info
      (Core <$> parseCoreCommand)
      (progDesc "Subcommands related to JuvixCore")

commandAsm :: Mod CommandFields DevCommand
commandAsm =
  command "asm" $
    info
      (Asm <$> parseAsmCommand)
      (progDesc "Subcommands related to JuvixAsm")

commandTree :: Mod CommandFields DevCommand
commandTree =
  command "tree" $
    info
      (Tree <$> parseTreeCommand)
      (progDesc "Subcommands related to JuvixTree")

commandCasm :: Mod CommandFields DevCommand
commandCasm =
  command "casm" $
    info
      (Casm <$> parseCasmCommand)
      (progDesc "Subcommands related to Cairo Assembly")

commandRuntime :: Mod CommandFields DevCommand
commandRuntime =
  command "runtime" $
    info
      (Runtime <$> parseRuntimeCommand)
      (progDesc "Subcommands related to the Juvix runtime")

commandParse :: Mod CommandFields DevCommand
commandParse =
  command "parse" $
    info
      (Parse <$> parseParse)
      (progDesc "Parse a Juvix file")

commandScope :: Mod CommandFields DevCommand
commandScope =
  command "scope" $
    info
      (Scope <$> parseScope)
      (progDesc "Parse and scope a Juvix file")

commandShowRoot :: Mod CommandFields DevCommand
commandShowRoot =
  command "root" $
    info
      (DisplayRoot <$> parseRoot)
      (progDesc "Show the root path for a Juvix project")

commandTermination :: Mod CommandFields DevCommand
commandTermination =
  command "termination" $
    info
      (Termination <$> parseTerminationCommand)
      (progDesc "Subcommands related to termination checking")

commandJuvixDevRepl :: Mod CommandFields DevCommand
commandJuvixDevRepl =
  command
    "repl"
    ( info
        (JuvixDevRepl <$> parseDevRepl)
        (progDesc "Run the Juvix dev REPL")
    )

commandMigrateJuvixYaml :: Mod CommandFields DevCommand
commandMigrateJuvixYaml =
  command "migrate-juvix-yaml" $
    info
      (MigrateJuvixYaml <$> parseMigrateJuvixYaml)
      (progDesc "Migrate juvix.yaml to Package.juvix in the current project")

commandNockma :: Mod CommandFields DevCommand
commandNockma =
  command "nockma" $
    info
      (Nockma <$> parseNockmaCommand)
      (progDesc "Subcommands related to the nockma backend")
