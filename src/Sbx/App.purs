-- | Linux container lifecycle, SQL clients and ZFS data branches.
module Sbx.App (run) where

import Prelude
import Bsdkrun as B
import Bsdkrun.Docker as Docker
import Bsdkrun.Host as Host
import Bsdkrun.Port as Port
import Bsdkrun.Sandbox as Sandbox
import Bsdkrun.Types (ZfsVolumeInfo)
import Bsdkrun.Zfs as Zfs
import Control.Alt ((<|>))
import Control.Monad.Error.Class (throwError)
import Data.Array as Array
import Data.Either (Either(..), either)
import Data.Foldable (for_)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe, isJust, maybe)
import Data.Nullable (toMaybe)
import Data.String as String
import Data.String.CodeUnits as CU
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple.Nested ((/\))
import Effect.Aff (Aff, attempt, delay, finally, forkAff, killFiber)
import Effect.Class (liftEffect)
import Effect.Console (log)
import Effect.Exception (error, message)
import Sbx.Bsd as Bsd
import Sbx.Cli (BranchOpts, Command(..), StartOpts)
import Sbx.Engine as Engine
import Sbx.DuckDB (versionAllowed, versionMajor)
import Sbx.Native as Native
import Sbx.Profile (ClientCmd(..), Creds, Os(..), Profile, osName, parseOs)
import Sbx.State (State)
import Sbx.State as State

run :: Profile -> Command -> Aff Int
run p cmd = do
  saved <- liftEffect (State.load p.tool)
  let requested = case cmd of
        Start o -> o.os
        _ -> Nothing
  for_ saved \st -> do
    when (parseOs st.os == Nothing) $ fail ("unknown guest OS in state: " <> st.os)
    for_ requested \os -> when (osName os /= st.os) $ fail ("this sandbox runs " <> st.os <> "; destroy it before changing the OS")
  let os = fromMaybe Linux ((saved >>= _.os >>> parseOs) <|> requested)
  if os == Linux then runLinux p cmd else Bsd.run p os cmd

runLinux :: Profile -> Command -> Aff Int
runLinux p = case _ of
  Start o -> start p o
  Stop -> stop p
  Status -> status p
  Shell -> shell p
  Exec o -> exec p o
  Logs o -> logs p o
  Branch o -> branch p o
  Checkout o -> checkout p o
  Url -> url p
  Client args -> client p args
  Token -> requireState p >>= \st -> say st.password $> 0
  Fancy -> fancy p
  Doctor -> doctor p
  Destroy o -> destroy p o

-- Helpers ------------------------------------------------------------------

say :: String -> Aff Unit
say = liftEffect <<< log

fail :: forall a. String -> Aff a
fail = throwError <<< error

findVolume :: Profile -> Aff (Maybe ZfsVolumeInfo)
findVolume p = Zfs.list <#> Array.find (_.name >>> eq p.tool)

requireVolume :: Profile -> Aff ZfsVolumeInfo
requireVolume p = findVolume p >>= maybe (fail ("no data volume yet — run `" <> p.tool <> " start` first")) pure

requireState :: Profile -> Aff State
requireState p = liftEffect (State.load p.tool) >>= maybe (fail ("no sandbox yet — run `" <> p.tool <> " start`")) pure

-- | All commands operate on the Linux container in the shared engine.
requireRunning :: Profile -> Aff { state :: State }
requireRunning p = do
  state <- requireState p
  up <- Engine.isRunning p
  unless up $ fail (p.tool <> " is stopped — run `" <> p.tool <> " start`")
  pure { state }

probeIn :: Profile -> Array String -> Aff Boolean
probeIn p argv = Docker.docker ([ "exec", Engine.containerName p ] <> argv) <#> (_.exitCode >>> eq 0)

-- | The branch a volume has mounted (bsdkrun records it even for a stopped
-- | holder); `main` on a volume nothing has imported yet.
mountedBranch :: ZfsVolumeInfo -> Maybe String
mountedBranch vol = Array.head (Array.concatMap _.mounts vol.attachedTo) <#> _.branch

currentBranch :: Profile -> Aff String
currentBranch p = do
  vol <- findVolume p
  st <- liftEffect (State.load p.tool)
  pure $ fromMaybe "main" ((vol >>= mountedBranch) <|> (st <#> _.branch))

branchNames :: ZfsVolumeInfo -> Array String
branchNames vol = Array.nub ([ "main" ] <> map _.name vol.branches)

creds :: State -> Creds
creds st = { user: st.user, password: st.password, db: st.db }

waitFor :: String -> Int -> Aff Boolean -> Aff Unit
waitFor what seconds check = go 0
  where
  go n
    | n >= seconds = fail (what <> " did not come up within " <> show seconds <> "s")
    | otherwise = check >>= \ok -> unless ok (delay (Milliseconds 1000.0) *> go (n + 1))

waitReady :: Profile -> State -> Aff Unit
waitReady p st = do
  say ("Waiting for " <> p.product <> " ...")
  waitFor p.product 180 do
    alive <- Engine.isRunning p
    unless alive $ fail ("the container exited while " <> p.product <> " was starting; `" <> p.tool <> " log` says why")
    probeIn p (p.ready Linux st.version (creds st))

checkVersion :: Profile -> Aff Unit
checkVersion p = do
  r <- Docker.docker [ "exec", Engine.containerName p, "duckdb", ":memory:", "-noheader", "-csv", "-c", "SELECT version();" ]
  unless (r.exitCode == 0) do
    Engine.removeContainer p
    fail ("cannot check DuckDB version: " <> String.trim r.stderr)
  unless (maybe false (_ >= 2) (versionMajor (String.trim r.stdout))) do
    Engine.removeContainer p
    fail ("duckdb-sbx requires DuckDB >= 2; image reports " <> String.trim r.stdout)

-- | The same for a container: its log follows on the terminal meanwhile.
withContainerLogs :: Boolean -> Profile -> Aff Unit -> Aff Unit
withContainerLogs false _ act = act
withContainerLogs true p act = do
  follower <- forkAff (void (attempt (Docker.dockerAttached [ "logs", "-f", Engine.containerName p ])))
  finally (killFiber (error "log stream closed") follower) act

-- | Forwarding is asynchronous, so wait for both the SQL probe in the
-- | container and the engine's loopback listener before declaring readiness.
waitHostPort :: Profile -> Int -> Aff Unit
waitHostPort p port = do
  waitFor ("host port " <> show port) 30 (not <$> Port.isFree port)
  local <- liftEffect (Native.loopbackListener port)
  unless local do
    Engine.removeContainer p
    fail "the engine published Quack beyond loopback; run `bsdkrun docker stop`, then `bsdkrun docker start --publish-bind 127.0.0.1`, and restart the sandbox"

ensurePort :: Profile -> Int -> Aff Unit
ensurePort p port = do
  result <- attempt $ waitFor ("host port " <> show port <> " to become free") 30 (Port.isFree port)
  case result of
    Right _ -> pure unit
    Left _ -> fail ("host port " <> show port <> " is in use; choose another with `" <> p.tool <> " start --port PORT`")

ready :: Profile -> State -> Aff Unit
ready p st = do
  say (p.product <> " is ready" <> (if p.hasServer then " on 127.0.0.1:" <> show st.port else "") <> " (branch " <> st.branch <> ")")
  say ("  " <> p.url st.version (creds st) st.port)

start :: Profile -> StartOpts -> Aff Int
start p o = do
  st <- liftEffect (State.load p.tool)
  startLinux p o st

startLinux :: Profile -> StartOpts -> Maybe State -> Aff Int
startLinux p o previous = do
  for_ previous \s -> do
    for_ o.version \v -> when (v /= s.version) $ fail ("this sandbox was created with version '" <> s.version <> "'; `" <> p.tool <> " destroy` to change it")
    when (isJust o.user || isJust o.db) $ say "note: credentials and the database were set when the data was initialised; the flags are ignored"
  generatedPassword <- liftEffect Native.randomPassword
  let
    version = fromMaybe p.defaultTag (map _.version previous <|> o.version)
    c = case previous of
      Just s -> { user: s.user, password: fromMaybe (if s.password == "" then generatedPassword else s.password) o.password, db: s.db }
      Nothing -> { user: "", password: fromMaybe generatedPassword o.password, db: fromMaybe p.defaults.db o.db }
    port = fromMaybe (maybe p.guestPort (\s -> if s.port == 0 then p.guestPort else s.port) previous) o.port
    cpus = fromMaybe (maybe 2 _.cpus previous) o.cpus
    mem = fromMaybe (maybe 1024 _.mem previous) o.mem
    size = fromMaybe "10G" o.size
  when (version == "" || Array.any (\w -> String.contains (String.Pattern w) version) [ " ", "\n", "\r", "\t" ]) $
    fail "VERSION must be an image tag or reference without whitespace"
  when (c.db == "" || not (Array.all (\ch -> (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') (CU.toCharArray c.db))) $
    fail "database name must contain only letters, digits, underscores or hyphens"
  when (String.length c.password < 4) $ fail "password must contain at least 4 characters"
  when (port < 1 || port > 65535) $ fail "port must be between 1 and 65535"
  unless (versionAllowed version) $ fail "duckdb-sbx requires DuckDB >= 2; choose a 2.x or newer image tag"
  when (maybe true (\s -> s.port /= port) previous) do
    free <- Port.isFree port
    unless free $ fail ("host port " <> show port <> " is in use; choose another with --port")
  vol <- findVolume p >>= case _ of
    Just v -> pure v
    Nothing -> do
      say ("Creating data volume '" <> p.tool <> "' (" <> size <> ", sparse) ...")
      _ <- Zfs.create p.tool (Just size)
      findVolume p >>= maybe (fail "the volume was created but does not show up") pure
  cur <- currentBranch p
  let branchName = fromMaybe cur o.branch
  unless (Array.elem branchName (branchNames vol)) $
    fail ("no branch '" <> branchName <> "'; branches: " <> String.joinWith ", " (branchNames vol))
  let st = { os: "linux", version, port, user: c.user, password: c.password, db: c.db, branch: branchName, cpus, mem }
  running <- Engine.isRunning p
  let unchanged = maybe false (\s -> s.port == port && s.password == c.password && s.branch == branchName && branchName == cur) previous
  when (isJust o.cpus || isJust o.mem) $ say ("note: on Linux --cpus/--mem do not limit the container; the engine VM is sized with `bsdkrun docker start --cpus N --mem M`")
  if running && unchanged then do
    checkVersion p
    waitReady p st
    waitHostPort p st.port
    say (p.tool <> " is already running (container in " <> Docker.machineName <> ", " <> p.image version <> ")")
    ready p st
    pure 0
  else do
    say ("Starting " <> p.product <> " " <> p.image version <> " as container '" <> Engine.containerName p <> "' in the Docker engine VM, branch " <> branchName <> " at " <> Engine.mountPoint p branchName <> " ...")
    -- The engine first: a stopped one hides the old container, which must
    -- go before the branch can move and before its name is reused.
    Engine.ensureEngine
    Engine.removeContainer p
    Engine.ensureAttached p vol branchName
    ensurePort p port
    liftEffect (State.save p.tool st)
    Engine.pullImage p st (not o.detach)
    Engine.runContainer p st c
    checkVersion p
    withContainerLogs (not o.detach) p (waitReady p st)
    waitHostPort p st.port
    ready p st
    pure 0

stop :: Profile -> Aff Int
stop p = do
  up <- Engine.isRunning p
  if not up then say (p.tool <> " is already stopped") $> 0
  else do
    r <- Docker.docker [ "stop", Engine.containerName p ]
    unless (r.exitCode == 0) $ fail ("docker stop: " <> String.trim r.stderr)
    say "stopped"
    pure 0

status :: Profile -> Aff Int
status p = do
  st <- liftEffect (State.load p.tool)
  case st of
    Nothing -> say ("no sandbox yet — run `" <> p.tool <> " start`") $> 0
    Just saved -> do
      engine <- Docker.status
      c <- Engine.container p
      cur <- currentBranch p
      color <- liftEffect Native.colorOutput
      let row k v = say ("  " <> k <> "  " <> v)
      let running = if color then Native.ansi "38;2;0;255;195" "RUNNING" else "RUNNING"
      say p.tool
      row "status" (if maybe false (_.state >>> eq "running") c then running else "STOPPED")
      row "engine" (Docker.machineName <> " " <> if engine.running then running else "STOPPED")
      row "image" (p.image saved.version)
      row "branch" (if color then Native.ansi "38;2;0;255;195" cur else cur)
      row "url" (p.url saved.version (creds saved) saved.port)
      when (maybe false (_.state >>> eq "running") c) do
        ok <- probeIn p (p.ready Linux saved.version (creds saved))
        row "database" (if ok then "ready" else "not ready yet")
      pure 0

shell :: Profile -> Aff Int
shell p = do
  _ <- requireRunning p
  Docker.dockerAttached [ "exec", "-it", Engine.containerName p, "sh" ]

exec :: Profile -> { tty :: Boolean, command :: Array String } -> Aff Int
exec p o = do
  when (Array.null o.command) $ fail ("nothing to run — `" <> p.tool <> " exec CMD...`")
  _ <- requireRunning p
  Docker.dockerAttached ([ "exec", if o.tty then "-it" else "-i", Engine.containerName p ] <> o.command)

logs :: Profile -> { follow :: Boolean, boot :: Boolean } -> Aff Int
logs p o = do
  if o.boot then do
    engine <- Docker.status
    id <- maybe (fail "the engine VM has not been created yet") pure (toMaybe engine.machineId)
    box <- B.get id
    if o.follow then Sandbox.followLogs true box else (B.logs true box >>= say) $> 0
  else do
    c <- Engine.container p
    when (c == Nothing) $ fail ("no container — run `" <> p.tool <> " start`")
    Docker.dockerAttached ([ "logs" ] <> (if o.follow then [ "-f" ] else []) <> [ Engine.containerName p ])

branch :: Profile -> BranchOpts -> Aff Int
branch p o = case o.name, o.arg of
  Just "ls", _ -> branch p o { name = Nothing }
  Just "list", _ -> branch p o { name = Nothing }
  Just "rm", Just name -> branch p o { name = Just name, arg = Nothing, delete = true }
  Just "delete", Just name -> branch p o { name = Just name, arg = Nothing, delete = true }
  Just "rm", Nothing -> fail ("which branch? `" <> p.tool <> " branch rm NAME`")
  Just "delete", Nothing -> fail ("which branch? `" <> p.tool <> " branch delete NAME`")
  _, Just extra -> fail ("unexpected argument '" <> extra <> "'")
  _, _ -> branch' p o

branch' :: Profile -> BranchOpts -> Aff Int
branch' p o = case o.name, o.delete of
  Nothing, _ -> do
    vol <- requireVolume p
    cur <- currentBranch p
    let
      origin b = maybe "" (\from -> "  (from " <> from <> ")") (toMaybe b.origin)
      known = map (\b -> b.name /\ origin b) vol.branches
      rows = if Array.any (fst' >>> eq "main") known then known else [ "main" /\ "  (initialised on first start)" ] <> known
    color <- liftEffect Native.colorOutput
    for_ rows \(name /\ note) -> do
      let label = (if name == cur then "* " else "  ") <> name
      say ((if color && name == cur then Native.ansi "38;2;0;255;195" label else label) <> note)
    pure 0
  Just name, true -> do
    vol <- requireVolume p
    cur <- currentBranch p
    when (name == "main") $ fail "main cannot be deleted; `destroy` removes the whole volume"
    when (name == cur) $ fail ("'" <> name <> "' is the mounted branch; checkout another one first")
    unless (Array.elem name (branchNames vol)) $ fail ("no branch '" <> name <> "'")
    Engine.ensureEngine
    Engine.ensureAttached p vol cur
    Zfs.destroy [ Zfs.target p.tool (Just name) ] false
    say ("Deleted branch '" <> name <> "'")
    pure 0
  Just name, false -> do
    vol <- requireVolume p
    cur <- currentBranch p
    let from = fromMaybe cur o.from
    when (Array.elem name (branchNames vol)) $ fail ("branch '" <> name <> "' already exists")
    unless (Array.elem from (branchNames vol)) $ fail ("no branch '" <> from <> "' to fork from")
    Engine.ensureEngine
    Engine.ensureAttached p vol cur
    say ("Forking " <> from <> " -> " <> name <> " ...")
    _ <- Zfs.branch p.tool name (Just from)
    say ("Branch '" <> name <> "' created. Switch to it with `" <> p.tool <> " checkout " <> name <> "`")
    pure 0
  where
  fst' (a /\ _) = a

checkout :: Profile -> { name :: String, create :: Boolean } -> Aff Int
checkout p o = do
  vol <- requireVolume p
  st <- requireState p
  cur <- currentBranch p
  when o.create do
    when (Array.elem o.name (branchNames vol)) $ fail ("branch '" <> o.name <> "' already exists")
    Engine.ensureEngine
    Engine.ensureAttached p vol cur
    say ("Forking " <> cur <> " -> " <> o.name <> " ...")
    void (Zfs.branch p.tool o.name (Just cur))
  unless (o.create || Array.elem o.name (branchNames vol)) $
    fail ("no branch '" <> o.name <> "' (`" <> p.tool <> " branch` lists them; `checkout -b " <> o.name <> "` creates it)")
  if o.name == cur then say ("already on '" <> o.name <> "'") $> 0
  else do
    running <- Engine.isRunning p
    when running $ say ("Stopping container '" <> Engine.containerName p <> "' ...")
    Engine.removeContainer p
    vol' <- requireVolume p
    Engine.ensureAttached p vol' o.name
    let st' = st { branch = o.name }
    liftEffect (State.save p.tool st')
    when running do
      say ("Starting " <> p.tool <> " on branch " <> o.name <> " ...")
      Engine.runContainer p st' (creds st)
      checkVersion p
      waitReady p st'
      waitHostPort p st'.port
    say ("Switched to branch '" <> o.name <> "'")
    pure 0

url :: Profile -> Aff Int
url p = do
  st <- requireState p
  say (p.url st.version (creds st) st.port)
  pure 0

client :: Profile -> Array String -> Aff Int
client p args = do
  { state: st } <- requireRunning p
  case p.client of
    Guest argv -> do
      tty <- liftEffect Native.isTty
      Docker.dockerAttached ([ "exec", if tty then "-it" else "-i", Engine.containerName p ] <> argv Linux st.version (creds st) <> args)
    Host _ -> fail "DuckDB clients run inside the Linux container"

fancy :: Profile -> Aff Int
fancy p = client p []

doctor :: Profile -> Aff Int
doctor p = do
  bin <- attempt (liftEffect Sandbox.resolveBinary)
  okBin <- check "bsdkrun" (either (const Nothing) Just bin) "not found: brew install tsirysndr/tap/bsdkrun"
  version <- attempt Host.version
  _ <- check "version" (either (const Nothing) Just version) "could not run `bsdkrun --version`"
  probed <- attempt Host.probe
  okProbe <- check "hypervisor"
    (case probed of
      Right true -> Just "libkrun context OK"
      _ -> Nothing)
    (case probed of
      Left e -> message e
      Right _ -> "`bsdkrun probe` failed: libkrun or the hypervisor is not usable")
  node <- liftEffect Native.nodeVersion
  let major = fromMaybe 0 (Int.fromString (String.takeWhile (_ /= String.codePointFromChar '.') (String.drop 1 node)))
  okNode <- check "node" (if major >= 22 then Just node else Nothing) (node <> " — Node 22 or newer is required")
  dockerCli <- liftEffect (Native.findExecutable "docker") <#> toMaybe
  okDocker <- check "docker" dockerCli "the docker CLI is not on PATH; Linux sandboxes run in bsdkrun's Docker engine, driven by it (brew install docker)"
  engine <- attempt Docker.status
  _ <- check "engine" (Just (case engine of
    Right e | e.running -> Docker.machineName <> " running, Docker " <> fromMaybe "?" (toMaybe e.version) <> ", " <> show (fromMaybe 0 (toMaybe e.containers)) <> " container(s)"
    Right e | isJust (toMaybe e.machineId) -> Docker.machineName <> " stopped (a Linux `start` starts it)"
    Right _ -> "none yet (a Linux `start` creates " <> Docker.machineName <> ")"
    Left e -> "could not ask bsdkrun: " <> message e)) ""
  st <- liftEffect (State.load p.tool)
  c <- Engine.container p
  _ <- check "sandbox" (Just (case st, c of
    _, Just container -> container.id <> " " <> container.state
    Nothing, _ -> "none yet (`" <> p.tool <> " start`)"
    _, _ -> "state recorded; `start` recreates the container")) ""
  pure (if okBin && okProbe && okNode && okDocker then 0 else 1)
  where
  check name result hint = case result of
    Just detail -> say ("  ok   " <> pad name <> detail) $> true
    Nothing -> say ("  FAIL " <> pad name <> hint) $> false
  pad s = String.take 13 (s <> "             ")

destroy :: Profile -> { yes :: Boolean } -> Aff Int
destroy p o = do
  st <- liftEffect (State.load p.tool)
  vol <- findVolume p
  c <- Engine.container p
  if Array.all isNothing' [ void st, void vol, void c ] then say "nothing to destroy" $> 0
  else do
    say "This removes the duckdb-sbx container, recorded settings and data volume with every branch."
    ok <- if o.yes then pure true else do
      tty <- liftEffect Native.isTty
      unless tty $ fail "not a terminal; pass --yes to confirm"
      Native.confirm "Destroy all of it? [y/N] "
    if not ok then say "aborted" $> 1
    else do
      Engine.removeContainer p
      for_ vol \v -> do
        Engine.detachVolume p v
        Zfs.destroy [ v.name ] true
      liftEffect (State.clear p.tool)
      say "Destroyed."
      pure 0
  where
  isNothing' = case _ of
    Nothing -> true
    Just _ -> false
