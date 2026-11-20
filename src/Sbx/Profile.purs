-- | DuckDB container settings, following the sibling sandbox profiles.
module Sbx.Profile where

import Prelude
import Data.Maybe (Maybe(..))
import Data.String as String
import Foreign.Object (Object)

data Os = Linux | FreeBSD | NetBSD

derive instance Eq Os

osName :: Os -> String
osName = case _ of
  Linux -> "linux"
  FreeBSD -> "freebsd"
  NetBSD -> "netbsd"

parseOs :: String -> Maybe Os
parseOs s = case String.toLower s of
  "linux" -> Just Linux
  "freebsd" -> Just FreeBSD
  "netbsd" -> Just NetBSD
  _ -> Nothing

type Creds = { user :: String, password :: String, db :: String }

-- | How the interactive client runs: with a PTY inside the guest, or as a
-- | host program (`node` script under the package root, given the host port).
data ClientCmd
  = Guest (Os -> String -> Creds -> Array String)
  | Host (Int -> Creds -> Array String)

type Profile =
  { tool :: String -- ^ the command name; also the machine and volume name
  , product :: String -- ^ "DuckDB"
  , hasServer :: Boolean -- ^ publish and wait for a TCP port
  , containerDockerfile :: Maybe (String -> String) -- ^ wrap a CLI-only image with a shell and an idle process
  , guestPort :: Int -- ^ the port the server listens on inside the guest
  , defaultTag :: String -- ^ Linux image tag when none is given
  , image :: String -> String -- ^ Linux image for a tag (or a full reference)
  , versionNote :: String -- ^ appended to the VERSION help: other values the tag may take
  , linuxOnly :: Boolean -- ^ only a Linux container in the engine
  , hasCredentials :: Boolean -- ^ whether --user/--password mean anything
  , defaults :: Creds
  , rootDisk :: Os -> Maybe String
  , provision :: Os -> Maybe String
  , dataDir :: Os -> String -- ^ where the ZFS branch is mounted (the data directory lives in it)
  , env :: Creds -> Object String -- ^ the Linux image's environment
  , command :: String -> Maybe (Array String) -- ^ override the Linux image's command, by version
  , ready :: Os -> String -> Creds -> Array String -- ^ exits 0 once the CLI is usable
  , client :: ClientCmd -- ^ the interactive client
  , clientName :: String -- ^ the subcommand that opens it ("duckdb")
  , clientAliases :: Array String -- ^ hidden aliases of that subcommand
  , fancy :: { name :: String } -- ^ additional CLI alias
  , url :: String -> Creds -> Int -> String -- ^ connection URL for a host port, by version
  , studioSupported :: Os -> String -> Boolean -- ^ whether drizzle-kit can reach it on that guest and version
  }

-- | Single-quote a string for a POSIX shell.
shellQuote :: String -> String
shellQuote s = "'" <> String.replaceAll (String.Pattern "'") (String.Replacement "'\\''") s <> "'"


-- | Package prefixes are not always on the guest agent PATH.
withBsdPath :: String -> Array String
withBsdPath cmd = [ "sh", "-c", "PATH=/usr/local/bin:/usr/pkg/bin:/usr/pkg/sbin:$PATH; exec " <> cmd ]
