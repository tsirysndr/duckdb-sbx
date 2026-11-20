-- | Dedicated BSD VMs with official DuckDB packages and a ZFS data disk.
module Sbx.Bsd (run, createOptions) where

import Prelude
import Bsdkrun as B
import Bsdkrun.Exec as Exec
import Bsdkrun.Host as Host
import Bsdkrun.Options as Options
import Bsdkrun.Sandbox as Sandbox
import Bsdkrun.Types (CreateOptions, Sandbox, SandboxInfo, ZfsVolumeInfo)
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
import Effect.Exception (error)
import Foreign.Object as Object
import Sbx.Cli (BranchOpts, Command(..), StartOpts)
import Sbx.DuckDB (versionCommand, versionMajor)
import Sbx.Native as Native
import Sbx.Profile (ClientCmd(..), Creds, Os(..), Profile, osName, parseOs)
import Sbx.State (State)
import Sbx.State as State

run :: Profile -> Os -> Command -> Aff Int
run p os = case _ of
  Start o -> start p os o
  Stop -> do
    m <- findMachine p
    for_ m \info -> when info.running $ void (B.get info.id >>= B.stop)
    say "stopped" $> 0
  Status -> status p
  Shell -> requireRunning p >>= Sandbox.shell
  Exec o -> do
    when (Array.null o.command) $ fail "nothing to run — use `exec CMD...`"
    box <- requireRunning p
    Sandbox.execAttached o.tty o.command box
  Logs o -> do
    box <- requireMachine p
    if o.follow then Sandbox.followLogs o.boot box
    else (B.logs o.boot box >>= say) $> 0
  Branch o -> branch p o
  Checkout o -> checkout p o
  Url -> requireState p >>= \st -> say (p.url st.version (creds st) st.port) $> 0
  Client -> client p os
  Fancy -> client p os
  Doctor -> doctor p
  Destroy o -> destroy p o.yes

say :: String -> Aff Unit
say = liftEffect <<< log

fail :: forall a. String -> Aff a
fail = throwError <<< error

findMachine :: Profile -> Aff (Maybe SandboxInfo)
findMachine p = B.list true <#> Array.find (\m -> toMaybe m.name == Just p.tool)

requireMachine :: Profile -> Aff Sandbox
requireMachine p = findMachine p >>= maybe (fail "the VM is gone — run `start`") (\m -> B.get m.id)

requireRunning :: Profile -> Aff Sandbox
requireRunning p = do
  box <- requireMachine p
  up <- B.isRunning box
  unless up $ fail (p.tool <> " is stopped — run `" <> p.tool <> " start`")
  pure box

findVolume :: Profile -> Aff (Maybe ZfsVolumeInfo)
findVolume p = Zfs.list <#> Array.find (_.name >>> eq p.tool)

requireVolume :: Profile -> Aff ZfsVolumeInfo
requireVolume p = findVolume p >>= maybe (fail ("no data volume yet — run `" <> p.tool <> " start` first")) pure

requireState :: Profile -> Aff State
requireState p = liftEffect (State.load p.tool) >>= maybe (fail ("no sandbox yet — run `" <> p.tool <> " start`")) pure

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

probe :: Array String -> Sandbox -> Aff Boolean
probe argv box = attempt (B.exec argv box) <#> either (const false) (_.exitCode >>> eq 0)

provision :: Profile -> Boolean -> Os -> Creds -> Sandbox -> Aff Unit
provision p stream os c box = for_ (p.provision os) \script -> do
  waitAgent p os box
  waitMounted p os box
  say ("Preparing " <> p.product <> " on " <> osName os <> " (the first time installs packages, which takes a minute or two) ...")
  let
    env = Object.fromFoldable [ "SBX_USER" /\ c.user, "SBX_PASSWORD" /\ c.password, "SBX_DB" /\ c.db ]
    opts = Exec.options # Exec.withEnv env
      # (if stream then Exec.withStdout Native.writeStdout >>> Exec.withStderr Native.writeStderr else identity)
  r <- B.execWith [ "sh", "-c", script ] opts box
  unless (r.exitCode == 0) do
    -- Quiet starts keep the output for the failure report.
    unless stream $ say (String.trim (r.stdout <> "\n" <> r.stderr))
    fail ("provisioning failed with exit " <> show r.exitCode)

-- | Wait for the guest agent. A BSD guest whose root disk was just grown
-- | resizes its file system and reboots (NetBSD does), which a detached
-- | machine reports as a clean exit: boot it again, once.
waitAgent :: Profile -> Os -> Sandbox -> Aff Unit
waitAgent p os box = go (isJust (p.rootDisk os)) 0
  where
  go mayReboot n
    | n >= 180 = fail "the guest agent did not come up within 180s"
    | otherwise = B.status box >>= case _ of
        Just m | m.running -> do
          ok <- probe [ "sh", "-c", "true" ] box
          unless ok (delay (Milliseconds 1000.0) *> go mayReboot (n + 1))
        Just m | mayReboot, maybe true (_ == 0) (toMaybe m.exitCode) -> do
          say "The guest grew its root disk and rebooted; starting it again ..."
          void (B.start box)
          go false 0
        _ -> fail ("the VM exited at boot; `" <> p.tool <> " log --boot` says why")

-- | bsdkrun imports a machine's ZFS volumes from a hook that runs beside the
-- | boot once the agent answers: wait for the data branch to be mounted. A
-- | fresh NetBSD guest gets its ZFS modules installed by that hook and can
-- | only load them at boot, so it is restarted once when the mount does not
-- | come: right away once the modules are in place, else after the wait.
waitMounted :: Profile -> Os -> Sandbox -> Aff Unit
waitMounted p os box = go (os == NetBSD)
  where
  dir = p.dataDir os
  mounted = probe [ "sh", "-c", "mount | grep -q ' on " <> dir <> " '" ] box
  modulesInstalledButNotLoaded = do
    m <- B.status box
    prepared <- maybe (pure false) (\i -> liftEffect (Native.fileExists (Native.pathJoin i.stateDir "zfs-netbsd-ready"))) m
    if not prepared then pure false else not <$> probe [ "sh", "-c", "modstat | grep -q '^zfs '" ] box
  go mayRestart = do
    outcome <- attempt $ waitFor ("the data branch at " <> dir) 90 do
      up <- mounted
      if up then pure true
      else if mayRestart then modulesInstalledButNotLoaded >>= \restart -> if restart then throwError (error "restart") else pure false
      else pure false
    case outcome of
      Right _ -> pure unit
      Left e
        | mayRestart -> do
            say "NetBSD now loads ZFS at boot: restarting the VM to import the data branch ..."
            void (B.stop box)
            void (B.start box)
            waitAgent p os box
            go false
        | otherwise -> throwError e

-- | Run an action while the VM console streams to the terminal (`start -d`
-- | skips it): everything the console holds for a VM just created, only what
-- | comes next for a restart, so the previous boot is not replayed. The
-- | follower is killed once the action is over.
withConsole :: Boolean -> Boolean -> Sandbox -> Aff Unit -> Aff Unit
withConsole false _ _ act = act
withConsole true fromStart box act = do
  follower <- forkAff (void (attempt (Sandbox.streamConsole fromStart box)))
  finally (killFiber (error "console stream closed") follower) act

bringUp :: Profile -> Boolean -> Os -> State -> Sandbox -> Aff Unit
bringUp p stream os st box = do
  provision p stream os (creds st) box
  r <- B.exec (versionCommand os) box
  unless (r.exitCode == 0 && maybe false (_ >= 2) (versionMajor (String.trim r.stdout))) do
    void (B.stop box)
    fail ("DuckDB >= 2 is required; official package reports " <> String.trim (r.stdout <> " " <> r.stderr) <> ". Update the guest package repository/package and rerun start.")
  ok <- probe (p.ready os st.version (creds st)) box
  unless ok $ fail "DuckDB readiness query failed"

-- | VERSION is the BSD OS release, never the DuckDB package version.
createOptions :: Profile -> Os -> State -> CreateOptions
createOptions p os st =
  (case os of
    FreeBSD -> Options.freebsd
    NetBSD -> Options.netbsd
    Linux -> Options.linux (p.image st.version))
  # (if st.version == "" then identity else Options.withVersion st.version)
  # maybe identity Options.withDiskSize (p.rootDisk os)
  # Options.withName p.tool
  # Options.withCpus st.cpus
  # Options.withMem st.mem
  # Options.withZfs [ Zfs.target p.tool (Just st.branch) <> ":" <> p.dataDir os ]

start :: Profile -> Os -> StartOpts -> Aff Int
start p os o = do
  previous <- liftEffect (State.load p.tool)
  for_ previous \s -> for_ o.version \v -> when (v /= s.version) $ fail "OS release is fixed; destroy the sandbox to change it"
  let
    st =
      { os: osName os
      , version: fromMaybe "" (map _.version previous <|> o.version)
      , port: 0, user: "", password: ""
      , db: fromMaybe p.defaults.db (map _.db previous <|> o.db)
      , branch: fromMaybe "main" (o.branch <|> map _.branch previous)
      , cpus: fromMaybe 2 (o.cpus <|> map _.cpus previous)
      , mem: fromMaybe 1024 (o.mem <|> map _.mem previous)
      }
  when (st.db == "" || not (Array.all (\ch -> (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-') (CU.toCharArray st.db))) $
    fail "database name must contain only letters, digits, underscores or hyphens"
  when (st.cpus <= 0 || st.mem <= 0) $ fail "cpus and mem must be positive"
  vol <- findVolume p >>= case _ of
    Just v -> pure v
    Nothing -> do
      void (Zfs.create p.tool (Just (fromMaybe "10G" o.size)))
      requireVolume p
  unless (Array.elem st.branch (branchNames vol)) $ fail ("no branch '" <> st.branch <> "'")
  m <- findMachine p
  case m of
    Nothing -> do
      box <- B.create (createOptions p os st)
      liftEffect (State.save p.tool st)
      withConsole (not o.detach) true box (bringUp p (not o.detach) os st box)
    Just info -> do
      when (previous == Nothing) $ fail "a VM with this name exists without recorded settings"
      box <- B.get info.id
      let cur = fromMaybe (fromMaybe "main" (map _.branch previous)) (mountedBranch vol)
      when (cur /= st.branch) do
        when info.running $ void (B.stop box)
        void (Zfs.detach (Zfs.target p.tool (Just cur)) info.id)
        void (Zfs.attachAt (Zfs.target p.tool (Just st.branch)) info.id (Just (p.dataDir os)))
      let resourcesChanged = maybe false (\s -> s.cpus /= st.cpus || s.mem /= st.mem) previous
      when resourcesChanged do
        up <- B.isRunning box
        when up $ void (B.stop box)
        void (B.update st.cpus st.mem box)
      liftEffect (State.save p.tool st)
      withConsole (not o.detach) false box do
        up <- B.isRunning box
        unless up $ void (B.start box)
        bringUp p (not o.detach) os st box
  say (p.product <> " is ready on " <> osName os <> " (branch " <> st.branch <> ")")
  pure 0

status :: Profile -> Aff Int
status p = do
  st <- requireState p
  m <- findMachine p
  say (p.tool <> " " <> st.os <> " " <> st.version <> " " <> if maybe false _.running m then "RUNNING" else "STOPPED")
  say ("  branch " <> st.branch)
  say ("  " <> p.url st.version (creds st) st.port)
  pure 0

client :: Profile -> Os -> Aff Int
client p os = do
  st <- requireState p
  box <- requireRunning p
  case p.client of
    Guest args -> Sandbox.execInteractive (args os st.version (creds st)) box
    Host _ -> fail "expected a guest DuckDB CLI"

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
    for_ rows \(name /\ note) -> say ((if name == cur then "* " else "  ") <> name <> note)
    pure 0
  Just name, true -> do
    vol <- requireVolume p
    cur <- currentBranch p
    when (name == "main") $ fail "main cannot be deleted; `destroy` removes the whole volume"
    when (name == cur) $ fail ("'" <> name <> "' is the mounted branch; checkout another one first")
    unless (Array.elem name (branchNames vol)) $ fail ("no branch '" <> name <> "'")
    Zfs.destroy [ Zfs.target p.tool (Just name) ] false
    say ("Deleted branch '" <> name <> "'")
    pure 0
  Just name, false -> do
    vol <- requireVolume p
    cur <- currentBranch p
    let from = fromMaybe cur o.from
    when (Array.elem name (branchNames vol)) $ fail ("branch '" <> name <> "' already exists")
    unless (Array.elem from (branchNames vol)) $ fail ("no branch '" <> from <> "' to fork from")
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
  os <- maybe (fail "unknown guest OS") pure (parseOs st.os)
  let cur = fromMaybe st.branch (mountedBranch vol)
  when o.create do
    when (Array.elem o.name (branchNames vol)) $ fail "branch already exists"
    void (Zfs.branch p.tool o.name (Just cur))
  unless (o.create || Array.elem o.name (branchNames vol)) $ fail ("no branch '" <> o.name <> "'")
  if o.name == cur then say ("already on '" <> cur <> "'") $> 0
  else do
    m <- findMachine p
    let st' = st { branch = o.name }
    for_ m \info -> do
      box <- B.get info.id
      when info.running $ void (B.stop box)
      void (Zfs.detach (Zfs.target p.tool (Just cur)) info.id)
      void (Zfs.attachAt (Zfs.target p.tool (Just o.name)) info.id (Just (p.dataDir os)))
      liftEffect (State.save p.tool st')
      when info.running do
        void (B.start box)
        bringUp p false os st' box
    liftEffect (State.save p.tool st')
    say ("Switched to branch '" <> o.name <> "'")
    pure 0

doctor :: Profile -> Aff Int
doctor p = do
  bin <- attempt (liftEffect Sandbox.resolveBinary)
  probed <- attempt Host.probe
  node <- liftEffect Native.nodeVersion
  let
    major = fromMaybe 0 (Int.fromString (String.takeWhile (_ /= String.codePointFromChar '.') (String.drop 1 node)))
    ok = case bin, probed of
      Right _, Right true -> major >= 22
      _, _ -> false
  say ("bsdkrun / hypervisor / Node: " <> if ok then "ok" else "FAILED")
  void (status p)
  pure (if ok then 0 else 1)

destroy :: Profile -> Boolean -> Aff Int
destroy p yes = do
  say "This removes the VM, recorded settings and data volume with every branch."
  confirmed <- if yes then pure true else do
    tty <- liftEffect Native.isTty
    unless tty $ fail "not a terminal; pass --yes to confirm"
    Native.confirm "Destroy all of it? [y/N] "
  if not confirmed then say "aborted" $> 1
  else do
    m <- findMachine p
    vol <- findVolume p
    for_ m \info -> do
      box <- B.get info.id
      when info.running $ void (B.stop box)
      for_ vol \_ -> void (Zfs.detach (Zfs.target p.tool Nothing) info.id)
      void (B.remove true box)
    for_ vol \v -> Zfs.destroy [ v.name ] true
    liftEffect (State.clear p.tool)
    say "Destroyed."
    pure 0
