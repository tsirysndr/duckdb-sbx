-- | DuckDB is embedded: keep the branch mounted in an idle container and
-- | open the database only for the lifetime of a client. There is no server.
module Sbx.DuckDB (profile, databaseFile, versionAllowed, versionMajor, versionCommand) where

import Prelude
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Array as Array
import Data.Int as Int
import Data.String as String
import Foreign.Object as Object
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
  , hasServer: false
  , guestPort: 0
  , defaultTag: "2.0.0"
  , image: \tag ->
      if String.contains (String.Pattern "/") tag || String.contains (String.Pattern ":") tag then tag
      else "duckdb/duckdb:" <> tag
  -- The official image is distroless: it contains /duckdb but no shell or
  -- sleep. Copy its CLI into Debian for ssh/exec and an idle PID 1.
  , containerDockerfile: Just \image -> String.joinWith "\n"
      [ "FROM " <> image <> " AS duckdb"
      , "FROM debian:bookworm-slim"
      , "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libstdc++6 && rm -rf /var/lib/apt/lists/*"
      , "COPY --from=duckdb /duckdb /usr/local/bin/duckdb"
      , "WORKDIR /var/lib/duckdb"
      , "CMD [\"sleep\", \"infinity\"]"
      , ""
      ]
  , versionNote: ". Requires DuckDB >= 2. DuckDB opens a file inside the guest; no TCP server or Drizzle support"
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
  , env: const Object.empty
  , command: const Nothing
  -- Probe an in-memory database: opening the branch's file could contend
  -- with a user's active writer. The file is created on first client use.
  , ready: \os _ _ -> case os of
      Linux -> [ "duckdb", ":memory:", "-c", "SELECT 1;" ]
      _ -> withBsdPath "duckdb :memory: -c 'SELECT 1;'"
  , client: Guest \os _ c -> case os of
      Linux -> [ "duckdb", databaseFile c.db ]
      _ -> withBsdPath ("duckdb " <> shellQuote (databaseFile c.db))
  , clientName: "duckdb"
  , clientAliases: [ "sql" ]
  , fancy: { name: "cli" }
  , url: \_ c _ -> "file " <> databaseFile c.db <> " in the guest (no server)"
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
