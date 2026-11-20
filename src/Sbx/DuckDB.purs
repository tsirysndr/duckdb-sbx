-- | Linux serves the branch database over Quack; BSD packages keep file access.
module Sbx.DuckDB (profile, databaseFile, versionAllowed, versionMajor, versionCommand) where

import Prelude
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Array as Array
import Data.Int as Int
import Data.String as String
import Foreign.Object as Object
import Data.Tuple.Nested ((/\))
import Sbx.Profile (ClientCmd(..), Os(..), Profile, shellQuote, withBsdPath)

databaseFile :: String -> String
databaseFile db = "/var/lib/duckdb/" <> db <> ".duckdb"

-- | Numeric tags can be rejected before creating any resources. Custom
-- | image tags and digests are checked against the actual CLI at startup.
versionMajor :: String -> Maybe Int
versionMajor raw = do
  let v = if String.take 1 raw == "v" then String.drop 1 raw else raw
  first <- Array.head (String.split (String.Pattern ".") v)
  Int.fromString first

versionAllowed :: String -> Boolean
versionAllowed ref =
  let tag = fromMaybe ref (Array.last (String.split (String.Pattern ":") ref))
  in case versionMajor tag of
    Just major -> major >= 2
    Nothing -> ref == "latest" || String.contains (String.Pattern "/") ref || String.contains (String.Pattern ":") ref

profile :: Profile
profile =
  { tool: "duckdb-sbx"
  , product: "DuckDB"
  , hasServer: true
  , guestPort: 9494
  , defaultTag: "2.0.0"
  , image: \tag ->
      if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag
      else "duckdb/duckdb:" <> tag
  -- The official image is distroless. Copy its CLI into Debian for
  -- server/client scripts and ssh/exec.
  , containerDockerfile: Just \image -> String.joinWith "\n"
      [ "FROM " <> image <> " AS duckdb"
      , "FROM debian:bookworm-slim"
      , "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libstdc++6 && rm -rf /var/lib/apt/lists/*"
      , "COPY --from=duckdb /duckdb /usr/local/bin/duckdb"
      , "WORKDIR /var/lib/duckdb"
      , "RUN duckdb :memory: -no-init -c 'INSTALL quack; INSTALL httpfs;'"
      , installScript "/usr/local/bin/duckdb-sbx-server" serverScript
      , installScript "/usr/local/bin/duckdb-sbx-client" clientScript
      , "CMD [\"duckdb-sbx-server\"]"
      , ""
      ]
  , versionNote: ". Requires DuckDB >= 2. Linux serves Quack on port 9494; BSD guests use file access. No Drizzle support"
  , linuxOnly: false
  , hasCredentials: false
  , defaults: { user: "", password: "", db: "duckdb" }
  , rootDisk: case _ of
      Linux -> Nothing
      _ -> Just "10G"
  , provision: case _ of
      Linux -> Nothing
      FreeBSD -> Just freebsd
      NetBSD -> Just netbsd
  , dataDir: const "/var/lib/duckdb"
  , env: \c -> Object.fromFoldable [ "SBX_DB" /\ c.db, "SBX_PASSWORD" /\ c.password ]
  , command: const Nothing
  -- Probe Linux through Quack: a second writer must never open its file.
  -- BSD remains an embedded CLI until suitable packages are available.
  , ready: \os _ _ -> case os of
      Linux -> [ "duckdb-sbx-client", "-noheader", "-csv", "-c", "SELECT 1;" ]
      _ -> withBsdPath "duckdb :memory: -c 'SELECT 1;'"
  , client: Guest \os _ c -> case os of
      Linux -> [ "duckdb-sbx-client" ]
      _ -> withBsdPath ("duckdb " <> shellQuote (databaseFile c.db))
  , clientName: "duckdb"
  , clientAliases: [ "sql" ]
  , fancy: { name: "cli" }
  , url: \_ _ port -> "quack:127.0.0.1:" <> show port
  , studioSupported: \_ _ -> false
  }

versionCommand :: Os -> Array String
versionCommand = case _ of
  Linux -> [ "duckdb", ":memory:", "-noheader", "-csv", "-c", "SELECT version();" ]
  _ -> withBsdPath "duckdb :memory: -noheader -csv -c 'SELECT version();'"

-- | Only official binary packages, installed onto the persistent root disk.
freebsd :: String
freebsd = String.joinWith "\n"
  [ "set -eu"
  , "export PATH=/usr/local/sbin:/usr/local/bin:$PATH ASSUME_ALWAYS_YES=yes"
  , "command -v duckdb >/dev/null 2>&1 || pkg install -y duckdb"
  , "mkdir -p /var/lib/duckdb"
  ]

netbsd :: String
netbsd = String.joinWith "\n"
  [ "set -eu"
  , "export PATH=/usr/pkg/sbin:/usr/pkg/bin:$PATH"
  , "A=$(uname -p); [ \"$A\" = x86_64 ] && A=amd64"
  , "export PKG_PATH=\"https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/$A/$(uname -r | cut -d. -f1).0/All/\""
  , "command -v duckdb >/dev/null 2>&1 || pkg_add duckdb"
  , "mkdir -p /var/lib/duckdb"
  ]

-- | Constant scripts read credentials from the environment, not command-line
-- | SQL interpolation. Restrict the external endpoint to host loopback in bsdkrun.
installScript :: String -> Array String -> String
installScript path lines = "RUN printf '%s\\n' " <> String.joinWith " " (map shellQuote lines) <> " > " <> path <> " && chmod 755 " <> path

serverScript :: Array String
serverScript =
  [ "#!/bin/sh"
  , "set -eu"
  , ": \"${SBX_DB:?}\" \"${SBX_PASSWORD:?}\""
  , "printf '%s\\n' " <> shellQuote serveInit <> " > /tmp/duckdb-sbx-serve.init"
  , "exec duckdb \"/var/lib/duckdb/$SBX_DB.duckdb\" -no-agent -init /tmp/duckdb-sbx-serve.init -serve"
  ]
  where
  serveInit = ".serve_command \"SELECT listen_url FROM quack_serve('quack:0.0.0.0:9494', allow_other_hostname = true, disable_ssl = true, token = getenv('SBX_PASSWORD'));\""

clientScript :: Array String
clientScript =
  [ "#!/bin/sh"
  , "set -eu"
  , "exec duckdb :memory: -no-agent -no-init -bail -cmd \"ATTACH 'quack:127.0.0.1:9494' AS sbx (TOKEN getenv('SBX_PASSWORD')); CONNECT sbx;\" \"$@\""
  ]
