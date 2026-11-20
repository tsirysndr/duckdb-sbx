module Ci.E2E (run, sandboxCli, redact) where

import Prelude
import Ci.Common as C
import Ci.Native as N
import Control.Monad.Error.Class (throwError)
import Data.Argonaut.Core as J
import Data.Array as A
import Data.Either (Either(..), either)
import Data.Foldable (any, for_)
import Data.Maybe (Maybe(..))
import Data.String as S
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, attempt, bracket, forkAff, killFiber, finally, delay)
import Data.Time.Duration (Milliseconds(..))
import Effect.Class (liftEffect)
import Effect.Console as Console
import Effect.Exception (message, error)
import Effect.Ref as Ref
import Foreign.Object as O
import Node.Process (setExitCode)
import Sbx.App as App
import Sbx.Cli as Cli
import Sbx.DuckDB (profile)

type Context =
  { name :: String, scratch :: String, logDir :: String, log :: String
  , env :: O.Object String, runtime :: String, node :: String, version :: String
  , started :: Ref.Ref Boolean, engineWasRunning :: Ref.Ref Boolean
  , occupied :: Ref.Ref (Maybe N.Port), succeeded :: Ref.Ref Boolean
  }

type Options = { allowFailure :: Boolean, secret :: Boolean, timeout :: Int, env :: O.Object String }
defaultOptions :: Options
defaultOptions = { allowFailure: false, secret: false, timeout: 300000, env: O.empty }

redact :: Array String -> Array String
redact args = A.mapWithIndex (\i arg -> if A.index args (i - 1) == Just "--password" then "<redacted>" else arg) args

record :: Context -> String -> Aff Unit
record c text = liftEffect $ N.appendText c.log (text <> "\n")
pass :: Context -> String -> Aff Unit
pass c text = liftEffect (Console.error ("PASS: " <> text)) *> record c ("PASS: " <> text)

command :: Context -> Options -> String -> Array String -> Aff N.Result
command c options program args = do
  let label = program <> " " <> S.joinWith " " (redact args)
  liftEffect (N.stream ("[e2e] $ " <> label <> "\n"))
  unless options.secret $ record c ("$ " <> label)
  let output chunk = unless options.secret (N.appendText c.log chunk *> N.stream chunk)
  heartbeat <- forkAff (waiting label 15)
  result <- finally (killFiber (error "command completed") heartbeat) $
    N.command { program, args, env: O.union options.env c.env, timeout: options.timeout, cwd: "", output }
  C.demand (program <> " failed (" <> show result.code <> ")" <> if options.secret then "" else ": " <> result.stderr) (options.allowFailure || result.code == 0)
  pure result
  where
  waiting label seconds = do
    delay (Milliseconds 15000.0)
    liftEffect $ N.stream ("[e2e] still running (" <> show seconds <> "s): " <> label <> "\n")
    waiting label (seconds + 15)

cliWith :: Context -> Options -> Array String -> Aff N.Result
cliWith c options args = command c options c.node ([ "bin/ci.js", "sandbox-cli", c.name ] <> args)
cli :: Context -> Array String -> Aff String
cli c args = S.trim <<< _.stdout <$> cliWith c defaultOptions args
runtime :: Context -> Array String -> Aff String
runtime c args = _.stdout <$> command c defaultOptions c.runtime args

password :: Context -> Aff String
password c = C.readJson (c.scratch <> "/config/" <> c.name <> "/state.json") >>= C.fromEither <<< C.stringField "password"

query :: Context -> String -> String -> String -> Boolean -> Aff String
query c client token sql reject = do
  uri <- cli c [ "url" ]
  C.demand "Invalid sandbox URI" (C.matches "^quack:127\\.0\\.0\\.1:[0-9]+$" uri)
  let attachSql = "ATTACH '" <> uri <> "' AS sandbox (TOKEN getenv('DUCKDB_SBX_E2E_PASSWORD')); CONNECT sandbox;"
  result <- command c (defaultOptions { allowFailure = reject, timeout = 120000, env = O.singleton "DUCKDB_SBX_E2E_PASSWORD" token }) client
    [ ":memory:", "-no-agent", "-no-init", "-bail", "-noheader", "-csv", "-cmd", attachSql, "-c", sql ]
  when reject $ C.demand "Incorrect password was accepted" (result.code /= 0)
  pure (S.trim result.stdout)

assertEqual :: String -> String -> Aff Unit
assertEqual expected actual = C.demand ("Expected " <> show expected <> ", got " <> show actual) (actual == expected)

freePort :: Aff Int
freePort = bracket N.reservePort (N.closePort <<< _.handle) (pure <<< _.port)

setup :: Aff Context
setup = do
  C.prepareRuntime
  name <- ("duckdb-sbx-e2e-" <> _) <$> liftEffect (N.randomHex 6)
  scratch <- liftEffect (N.tempDir "duckdb-sbx-e2e-")
  logDir <- C.fallback "DUCKDB_SBX_E2E_LOG_DIR" ".fluentci/test-logs" >>= liftEffect <<< N.resolve
  let log = logDir <> "/e2e.log"
  liftEffect (N.mkdir logDir *> N.writeText log "")
  runtimePath <- C.bsdkrun
  node <- liftEffect N.node
  version <- C.projectVersion
  started <- liftEffect (Ref.new false)
  engineWasRunning <- liftEffect (Ref.new true)
  occupied <- liftEffect (Ref.new Nothing)
  succeeded <- liftEffect (Ref.new false)
  pure { name, scratch, logDir, log, node, version, started, engineWasRunning, occupied, succeeded
       , runtime: runtimePath
       , env: O.fromFoldable [ "XDG_CONFIG_HOME" /\ (scratch <> "/config"), "NO_COLOR" /\ "1", "BSDKRUN_NO_AUTO_INSTALL" /\ "1" ] }

body :: Context -> Aff Unit
body c = do
  before <- runtime c [ "docker", "status", "--json" ] >>= C.fromEither <<< C.jsonSuffix
  wasRunning <- C.fromEither (C.boolField "running" before)
  liftEffect (Ref.write wasRunning c.engineWasRunning)
  void $ runtime c [ "probe" ]
  machines <- runtime c [ "ps", "--all", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
  volumes <- runtime c [ "zfs", "ls", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
  let named item = C.stringField "name" item == Right c.name
  C.demand "E2E sandbox already exists" (not (any named machines || any named volumes))
  binary <- liftEffect (N.resolve "dist/duckdb-sbx")
  result <- command c defaultOptions binary [ "--version" ]
  assertEqual ("duckdb-sbx " <> c.version) (S.trim result.stdout)
  host <- liftEffect N.platform
  let os = if host.os == "darwin" then "osx" else host.os
  let arch = if host.arch == "x64" then "amd64" else host.arch
  let target = os <> "-" <> arch
  C.demand "Unsupported E2E host" (A.elem target [ "linux-amd64", "linux-arm64", "osx-arm64" ])
  let clientDir = c.scratch <> "/client"
  let client = clientDir <> "/duckdb"
  liftEffect (N.mkdir clientDir)
  void $ command c defaultOptions "curl" [ "--fail", "--show-error", "--silent", "--location", "--retry", "3", "https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-cli-" <> target <> ".tar.gz", "-o", c.scratch <> "/client.tar.gz" ]
  void $ command c defaultOptions "tar" [ "-xzf", c.scratch <> "/client.tar.gz", "-C", clientDir ]
  liftEffect (N.chmod client 493)
  initial <- ("e2e-" <> _) <$> liftEffect (N.randomHex 24)
  port <- freePort
  liftEffect (Ref.write true c.started)
  void $ cliWith c (defaultOptions { timeout = 600000 }) [ "start", "linux", "2.0.0", "--password", initial, "--port", show port, "-d" ]
  cli c [ "url" ] >>= assertEqual ("quack:127.0.0.1:" <> show port)
  token <- cliWith c (defaultOptions { secret = true }) [ "token" ]
  C.demand "Configured token was not retained" (S.trim token.stdout == initial)
  query c client initial "SELECT version();" false >>= assertEqual "v2.0.0"
  query c client initial "SELECT 42;" false >>= assertEqual "42"
  void $ query c client "wrong-password" "SELECT 1;" true
  pass c "host Quack client authenticated; incorrect password rejected"
  void $ query c client initial "CREATE TABLE e2e_values AS SELECT 42 AS n;" false
  cli c [ "duckdb", "-noheader", "-csv", "-c", "SELECT n FROM e2e_values;" ] >>= assertEqual "42"
  void $ cli c [ "checkout", "-b", "feature" ]
  void $ query c client initial "UPDATE e2e_values SET n=7;" false
  query c client initial "SELECT n FROM e2e_values;" false >>= assertEqual "7"
  void $ cli c [ "checkout", "main" ]
  query c client initial "SELECT n FROM e2e_values;" false >>= assertEqual "42"
  void $ cli c [ "branch", "-d", "feature" ]
  pass c "ZFS branch writes are isolated and main retains its data"
  collisionPort <- N.reservePort
  liftEffect (Ref.write (Just collisionPort.handle) c.occupied)
  collision <- cliWith c (defaultOptions { allowFailure = true }) [ "start", "--port", show collisionPort.port, "-d" ]
  C.demand "Occupied port was accepted" (collision.code /= 0)
  query c client initial "SELECT n FROM e2e_values;" false >>= assertEqual "42"
  N.closePort collisionPort.handle
  liftEffect (Ref.write Nothing c.occupied)
  pass c "port collision preserves the running server"
  nextPort <- freePort
  rotated <- ("quoted-'\"-" <> _) <$> liftEffect (N.randomHex 24)
  void $ cli c [ "start", "--port", show nextPort, "--password", rotated, "-d" ]
  cli c [ "url" ] >>= assertEqual ("quack:127.0.0.1:" <> show nextPort)
  query c client rotated "SELECT n FROM e2e_values;" false >>= assertEqual "42"
  void $ query c client initial "SELECT 1;" true
  void $ cli c [ "stop" ]
  stopped <- cli c [ "status" ]
  C.demand "Sandbox did not stop" (S.contains (S.Pattern "STOPPED") stopped)
  void $ cli c [ "start", "-d" ]
  query c client rotated "SELECT n FROM e2e_values;" false >>= assertEqual "42"
  saved <- password c
  C.demand "Password rotation was not persisted" (saved == rotated)
  serverLog <- cli c [ "log" ]
  C.demand "Server log exposed the password" (not (S.contains (S.Pattern rotated) serverLog))
  pass c "quoted password rotation, port change and stop/start preserve data and credentials"
  liftEffect (Ref.write true c.succeeded)

cleanup :: Context -> Aff Unit
cleanup c = do
  result <- attempt do
    occupied <- liftEffect (Ref.read c.occupied)
    for_ occupied N.closePort
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "ps", "--all", "--json" ]
    -- Capture the actual post-restart mount/driver state, not just whether
    -- the host data.img file exists. No state files or credentials are copied.
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "docker", "status", "--json" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "cat", "/proc/mounts" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "stat", "-f", "-c", "%T", "/var/lib/docker" ]
    void $ command c (defaultOptions { allowFailure = true, timeout = 15000 }) c.runtime [ "exec", "bsdkrun-docker", "cat", "/proc/1/limits" ]
    started <- liftEffect (Ref.read c.started)
    when started do
      void $ cliWith c (defaultOptions { allowFailure = true, timeout = 15000 }) [ "log" ]
      void $ cliWith c (defaultOptions { timeout = 120000 }) [ "destroy", "--yes" ]
    after <- runtime c [ "zfs", "ls", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
    C.demand "E2E data volume leaked" (not (any (\j -> C.stringField "name" j == Right c.name) after))
    wasRunning <- liftEffect (Ref.read c.engineWasRunning)
    unless wasRunning do
      running <- runtime c [ "docker", "ps", "--json" ] >>= C.fromEither <<< (C.jsonSuffix >=> C.jsonArray)
      when (A.null running) $ void $ runtime c [ "docker", "stop" ]
    pass c "temporary sandbox removed; existing engine/services preserved"
  succeeded <- liftEffect (Ref.read c.succeeded)
  let ok = succeeded && either (const false) (const true) result
  liftEffect do
    N.writeText (c.logDir <> "/result.json") $ J.stringify $ J.fromObject $ O.fromFoldable
      [ "passed" /\ J.fromBoolean ok, "sandbox" /\ J.fromString c.name ]
    N.remove c.scratch
  case result of
    Left err -> record c ("CLEANUP FAILED: " <> message err) *> throwError err
    Right _ -> pure unit

run :: Aff Unit
run = bracket setup cleanup \c -> do
  result <- attempt (body c)
  case result of
    Left err -> record c ("FAIL: " <> message err) *> throwError err
    Right _ -> pure unit

sandboxCli :: String -> Array String -> Aff Unit
sandboxCli name args = do
  C.demand "Missing isolated E2E sandbox name" (C.matches "^duckdb-sbx-e2e-[a-f0-9]{12}$" name)
  version <- C.projectVersion
  let isolated = profile { tool = name }
  cmd <- liftEffect (N.setArgs args *> Cli.parseCommand isolated version)
  App.run isolated cmd >>= liftEffect <<< setExitCode
