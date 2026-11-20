-- | Sandbox command line, parsed with optparse.
module Sbx.Cli
  ( Command(..)
  , StartOpts
  , BranchOpts
  , parseCommand
  ) where

import Prelude
import Control.Alt ((<|>))
import Data.Array as Array
import Data.Either (Either(..))
import Data.Foldable (fold)
import Data.Maybe (Maybe(..), optional)
import Effect (Effect)
import Options.Applicative (Parser, ReadM, argument, command, commandGroup, customExecParser, eitherReader, footer, forwardOptions, fullDesc, header, help, helper, hidden, info, infoOption, int, long, many, metavar, option, prefs, progDesc, short, showHelpOnEmpty, strArgument, strOption, subparser, switch)
import Sbx.Profile (Os, Profile, parseOs)

type StartOpts =
  { os :: Maybe Os
  , version :: Maybe String
  , port :: Maybe Int
  , user :: Maybe String
  , password :: Maybe String
  , db :: Maybe String
  , cpus :: Maybe Int
  , mem :: Maybe Int
  , branch :: Maybe String
  , size :: Maybe String
  , detach :: Boolean -- ^ quiet start: no VM console or provisioning output
  }

type BranchOpts = { name :: Maybe String, arg :: Maybe String, delete :: Boolean, from :: Maybe String }

data Command
  = Start StartOpts
  | Stop
  | Status
  | Shell
  | Exec { tty :: Boolean, command :: Array String }
  | Logs { follow :: Boolean, boot :: Boolean }
  | Branch BranchOpts
  | Checkout { name :: String, create :: Boolean }
  | Url
  | Client
  | Fancy
  | Doctor
  | Destroy { yes :: Boolean }

osReader :: Profile -> ReadM Os
osReader p = eitherReader \s -> case parseOs s of
  Just os -> Right os
  Nothing -> Left (p.tool <> " expected linux, freebsd or netbsd, got '" <> s <> "'")

startP :: Profile -> Parser Command
startP p = ado
  os <- optional $ argument (osReader p) $ fold
    [ metavar "linux|freebsd|netbsd"
    , help "Guest OS (default linux): shared Docker engine on Linux, dedicated VM on FreeBSD/NetBSD"
    ]
  version <- optional $ strArgument $ fold
    [ metavar "VERSION", help ("Linux: image tag, e.g. " <> p.defaultTag <> ", or a full image reference (default: " <> p.defaultTag <> ")" <> p.versionNote <> ". FreeBSD/NetBSD: OS release (default latest), DuckDB comes from official packages") ]
  port <- if p.hasServer then optional $ option int $ fold
    [ long "port", short 'p', metavar "PORT", help ("Host port forwarded to " <> p.product <> " (default: " <> show p.guestPort <> ")") ]
    else pure Nothing
  user <- credential "user" ("Superuser name (default: " <> p.defaults.user <> ")")
  password <- credential "password" ("Its password (default: " <> p.defaults.password <> ")")
  db <- optional $ strOption $ fold
    [ long "db", metavar "NAME", help ("Database filename, created on first client use (default: " <> p.defaults.db <> ")") ]
  cpus <- optional $ option int $ fold [ long "cpus", metavar "N", help "BSD guest vCPUs (default 2); size the shared Linux VM with `bsdkrun docker start --cpus N`" ]
  mem <- optional $ option int $ fold [ long "mem", metavar "MIB", help "BSD guest RAM in MiB (default 1024); size the shared Linux VM with `bsdkrun docker start --mem MIB`" ]
  branch <- optional $ strOption $ fold
    [ long "branch", short 'b', metavar "BRANCH", help "Data branch to mount (default: the current one, main at first)" ]
  size <- optional $ strOption $ fold
    [ long "size", metavar "SIZE", help "Data volume size when it is created, e.g. 10G (sparse; default: 10G)" ]
  detach <- switch $ fold
    [ long "detach", short 'd', help "Quiet start: do not stream the VM console and the provisioning output" ]
  in Start { os, version, port, user, password, db, cpus, mem, branch, size, detach }
  where
  credential name doc
    | p.hasCredentials = optional $ strOption $ fold [ long name, metavar (if name == "user" then "NAME" else "SECRET"), help doc ]
    | otherwise = pure Nothing

logsP :: Parser Command
logsP = ado
  follow <- switch $ fold [ long "follow", short 'f', help "Keep streaming the console" ]
  boot <- switch $ fold [ long "boot", help "bsdkrun's own boot log instead of the guest console" ]
  in Logs { follow, boot }

branchP :: Parser Command
branchP = ado
  delete <- switch $ fold [ long "delete", short 'd', help "Delete NAME instead of creating it" ]
  from <- optional $ strOption $ fold [ long "from", metavar "BRANCH", help "Branch to fork from (default: the current one)" ]
  name <- optional $ strArgument $ fold [ metavar "NAME", help "Branch to create (or delete with -d). Without it, list branches. Also: `ls`, `rm NAME`" ]
  arg <- optional $ strArgument $ fold [ metavar "ARG", help "The branch for `rm` / `delete`" ]
  in Branch { name, arg, delete, from }

checkoutP :: Parser Command
checkoutP = ado
  create <- switch $ fold [ long "create", short 'b', help "Create NAME from the current branch first" ]
  name <- strArgument $ fold [ metavar "BRANCH", help "Branch to mount as the data directory" ]
  in Checkout { name, create }

execP :: Parser Command
execP = ado
  tty <- switch $ fold [ long "tty", short 't', help "Allocate a pseudo-terminal (for shells, editors and prompts)" ]
  command <- many $ strArgument $ fold [ metavar "CMD...", help "The command and its arguments, run as root through the guest agent" ]
  in Exec { tty, command: Array.fromFoldable command }

destroyP :: Parser Command
destroyP = ado
  yes <- switch $ fold [ long "yes", short 'y', help "Do not ask for confirmation" ]
  in Destroy { yes }

commands :: Profile -> Parser Command
commands p = base
  where
  base = subparser
    ( fold
        [ command "start" $ info (helper <*> startP p) $ fold
            [ progDesc ("Start the sandbox, creating the guest and its data volume on first run")
            , footer ("The database name and version are recorded on first start; later starts reuse them. Example: " <> p.tool <> " start linux " <> p.defaultTag)
            ]
        , command "stop" $ info (pure Stop) $ progDesc "Stop the sandbox (data stays on its branch)"
        , command "status" $ info (pure Status) $ progDesc "Show the guest, mounted branch and database file"
        , command "ssh" $ info (pure Shell) $ progDesc "Open a shell in the guest (alias: shell)"
        , command "exec" $ info (helper <*> execP) $ fold
            [ progDesc "Run a command in the guest with your stdin, stdout and stderr bound to it"
            , footer ("Example: " <> p.tool <> " exec -t sh, " <> p.tool <> " exec " <> "sh -c 'ls /var/lib/duckdb'")
            , forwardOptions
            ]
        , command "log" $ info (helper <*> logsP) $ progDesc "Show the guest log, -f to follow (alias: logs)"
        , command "branch" $ info (helper <*> branchP) $ fold
            [ progDesc "List data branches, create one (copy-on-write) or delete one"
            , footer ("Like git: `" <> p.tool <> " branch` (or `branch ls`) lists, `" <> p.tool <> " branch NAME` forks the current branch, `" <> p.tool <> " branch -d NAME` (or `branch rm NAME`) deletes, `" <> p.tool <> " checkout NAME` switches.")
            ]
        , command "checkout" $ info (helper <*> checkoutP) $ progDesc "Switch the data directory to BRANCH, -b to create it first (alias: switch)"
        , command p.clientName $ info (pure Client) $ progDesc ("Open " <> p.clientName <> " on the sandbox database")
        , command p.fancy.name $ info (pure Fancy) $ progDesc ("Open " <> p.fancy.name <> " on the sandbox database")
        , command "url" $ info (pure Url) $ progDesc "Print the database file location in the guest"
        , command "doctor" $ info (pure Doctor) $ progDesc "Check bsdkrun, the hypervisor, Node and Docker"
        , command "destroy" $ info (helper <*> destroyP) $ progDesc "Remove the sandbox and the data volume with every branch (asks first)"
        ]
    )
    <|> subparser
      ( fold
          ( map (\alias -> command alias $ info (pure Client) $ progDesc ("Alias of " <> p.clientName)) p.clientAliases <>
          [ command "shell" $ info (pure Shell) $ progDesc "Alias of ssh"
          , command "logs" $ info (helper <*> logsP) $ progDesc "Alias of log"
          , command "switch" $ info (helper <*> checkoutP) $ progDesc "Alias of checkout"
          , commandGroup "Aliases:"
          , hidden
          ]
          )
      )
-- | The out-of-the-box choices, for the top-level help.
defaultsLine :: Profile -> String
defaultsLine p = "Defaults: linux " <> p.image p.defaultTag <> (if p.hasServer then ", host port " <> show p.guestPort <> " on 127.0.0.1" else ", embedded database in the container") <> ", data volume 10G"
  <> (if p.hasCredentials then ", user " <> p.defaults.user <> ", password " <> p.defaults.password <> ", database " <> p.defaults.db else "")
  <> ". `start --help` lists the flags that change them."

parseCommand :: Profile -> String -> Effect Command
parseCommand p version = customExecParser (prefs showHelpOnEmpty) $ info (helper <*> versionOption <*> commands p) $ fold
  [ fullDesc
  , header (p.tool <> " — " <> p.product <> " in a bsdkrun microVM, with branchable data")
  , progDesc ("One " <> p.product <> " database per sandbox, in bsdkrun's shared Linux Docker engine or a dedicated BSD VM. Its data directory is a ZFS branch: fork it copy-on-write, switch between branches, throw them away.")
  , footer (defaultsLine p)
  ]
  where
  versionOption = infoOption (p.tool <> " " <> version) $ fold [ long "version", help "Show the version" ]
