module Test.Main where

import Prelude
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String as String
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (throw)
import Sbx.DuckDB (profile, databaseFile, versionAllowed)
import Bsdkrun.Options as Options
import Sbx.Bsd (createOptions)
import Sbx.Engine (mountPoint, runArgs, runtimeVersionAllowed)
import Sbx.Profile (ClientCmd(..), Os(..), parseOs)

assert :: String -> Boolean -> Effect Unit
assert name ok = unless ok (throw name)

main :: Effect Unit
main = do
  let
    c = profile.defaults { password = "unit-secret" }
    st = { os: "linux", version: "latest", port: 9494, user: "", password: "", db: c.db, branch: "feature", cpus: 2, mem: 1024 }
  assert "minimum DuckDB version" (not (versionAllowed "1.4.5") && not (versionAllowed "v1.5.6") && not (versionAllowed "duckdb/duckdb:1.4.5") && versionAllowed "2.0.0" && versionAllowed "3.0.0" && profile.defaultTag == "2.0.0")
  assert "official image tags" (profile.image "2.0.0" == "duckdb/duckdb:2.0.0")
  assert "custom image reference" (profile.image "ghcr.io/example/duckdb:dev" == "ghcr.io/example/duckdb:dev")
  assert "database path" (databaseFile "analytics" == "/var/lib/duckdb/analytics.duckdb")
  assert "Quack URI" (profile.url "latest" c 9494 == "quack:127.0.0.1:9494")
  assert "Linux Quack server" (not profile.linuxOnly && profile.hasServer && not profile.hasCredentials && not (profile.studioSupported Linux "latest"))
  assert "readiness queries the remote server" (profile.ready Linux "latest" c == [ "duckdb-sbx-client", "-noheader", "-csv", "-c", "SELECT 1;" ])
  case profile.client of
    Guest args -> assert "Linux CLI connects to the server" (args Linux "latest" (c { db = "analytics" }) == [ "duckdb-sbx-client" ])
    _ -> throw "expected guest CLI"
  assert "branch mountpoint" (mountPoint profile "feature" == "/mnt/duckdb-sbx-feature")
  assert "container keeps stdin open and publishes authenticated Quack"
    (runArgs profile st c == [ "run", "-d", "-i", "--init", "--name", "duckdb-sbx", "--restart", "unless-stopped", "-p", "9494:9494", "-v", "/mnt/duckdb-sbx-feature:/var/lib/duckdb", "-e", "SBX_DB=duckdb", "-e", "SBX_PASSWORD=unit-secret", "duckdb-sbx-runtime" ])
  assert "switch mounts another branch" (Array.elem "/mnt/duckdb-sbx-main:/var/lib/duckdb" (runArgs profile (st { branch = "main" }) c))
  case profile.containerDockerfile of
    Nothing -> throw "official distroless image needs a runtime wrapper"
    Just dockerfile -> do
      let built = dockerfile (profile.image "2.0.0")
      assert "runtime copies pinned official CLI" (String.contains (String.Pattern "FROM duckdb/duckdb:2.0.0 AS duckdb") built && String.contains (String.Pattern "COPY --from=duckdb /duckdb /usr/local/bin/duckdb") built)
  assert "BSD OS parsing" (parseOs "freebsd" == Just FreeBSD && parseOs "NetBSD" == Just NetBSD && parseOs "openbsd" == Nothing)
  assert "BSD disks have room for packages" (profile.rootDisk FreeBSD == Just "10G" && profile.rootDisk NetBSD == Just "10G")
  case profile.provision FreeBSD, profile.provision NetBSD of
    Just freebsd, Just netbsd -> do
      assert "FreeBSD official package" (String.contains (String.Pattern "pkg install -y duckdb") freebsd)
      assert "NetBSD official package" (String.contains (String.Pattern "pkg_add duckdb") netbsd && String.contains (String.Pattern "cdn.NetBSD.org") netbsd)
    _, _ -> throw "missing BSD provisioning"
  let args = Options.buildCreateArgs (createOptions profile FreeBSD (st { os = "freebsd", version = "15.1" }))
  assert "BSD creation uses release, ZFS branch and root disk, no TCP port"
    (args == [ "freebsd", "-d", "--version", "15.1", "--name", "duckdb-sbx", "--cpus", "2", "--mem", "1024", "--zfs", "duckdb-sbx@feature:/var/lib/duckdb", "--disk-size", "10G" ])
  assert "new engines require the fixed runtime" (not (runtimeVersionAllowed "bsdkrun 0.12.0") && not (runtimeVersionAllowed "bsdkrun 0.11.99"))
  assert "fixed and newer runtimes are accepted" (runtimeVersionAllowed "bsdkrun 0.12.1\n" && runtimeVersionAllowed "bsdkrun 0.13.0" && runtimeVersionAllowed "bsdkrun 1.0.0")
  assert "unrecognized runtime versions fail clearly" (not (runtimeVersionAllowed "unknown"))
  log "duckdb-sbx tests passed"
