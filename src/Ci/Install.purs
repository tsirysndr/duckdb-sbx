module Ci.Install (install, verifyDriver) where

import Prelude
import Ci.Common as C
import Ci.Native as N
import Data.Array as A
import Data.Maybe (fromMaybe)
import Data.String as S
import Effect.Aff (Aff)
import Effect.Console (log)
import Effect.Class (liftEffect)

-- The CI runner is disposable. VFS deliberately avoids depending on overlayfs
-- over the VM's host-backed virtio-fs filesystem on Linux/KVM.
verifyDriver :: String -> Aff Unit
verifyDriver runtime = do
  status <- C.run runtime [ "docker", "status", "--json" ] >>= C.fromEither <<< C.jsonSuffix <<< _.stdout
  socket <- C.fromEither (C.stringField "socket" status)
  info <- C.run "docker" [ "--host", "unix://" <> socket, "info", "--format", "{{.Driver}}" ]
  C.demand "CI requires the Docker VFS driver (containerd snapshotter disabled)" (S.trim info.stdout == "vfs")

install :: String -> Aff Unit
install version = do
  C.demand "Expected a bsdkrun release such as v0.12.0" (C.matches "^v[0-9]+\\.[0-9]+\\.[0-9]+$" version)
  host <- liftEffect N.platform
  C.demand "The installer requires Ubuntu x86_64 with KVM" (host.os == "linux" && host.arch == "x64")
  liftEffect (N.exists "/dev/kvm") >>= C.demand "/dev/kvm is required; live tests are never skipped"
  void $ C.run "sudo" [ "-n", "apt-get", "update" ]
  void $ C.run "sudo" [ "-n", "apt-get", "install", "-y", "--no-install-recommends", "ca-certificates", "curl", "tar", "gzip", "xz-utils", "util-linux", "libgmp10", "libtinfo6" ]
  void $ C.run "sudo" [ "-n", "chmod", "a+rw", "/dev/kvm" ]
  liftEffect (N.readableWritable "/dev/kvm") >>= C.demand "KVM must be readable and writable"
  void $ C.run "docker" [ "--version" ]
  root <- liftEffect (N.resolve ".fluentci/tools/bsdkrun")
  let bin = root <> "/bin"
  liftEffect (N.mkdir bin)
  let asset = "bsdkrun-x86_64-unknown-linux-gnu.tar.gz"
  let base = "https://github.com/tsirysndr/bsdkrun/releases/download/" <> version <> "/" <> asset
  download base (root <> "/" <> asset)
  download (base <> ".sha256") (root <> "/" <> asset <> ".sha256")
  checksum <- liftEffect (N.readText (root <> "/" <> asset <> ".sha256"))
  actual <- liftEffect (N.sha256 (root <> "/" <> asset))
  let expected = fromMaybe "" (A.head (S.split (S.Pattern " ") (S.trim checksum)))
  C.demand "bsdkrun release checksum mismatch" (C.matches "^[a-fA-F0-9]{64}$" expected && S.toLower expected == actual)
  void $ C.run "tar" [ "-xzf", root <> "/" <> asset, "-C", bin ]
  -- Linux CLI bundles supervisor + libkrun/libkrunfw beside the executable.
  download "https://github.com/containers/gvisor-tap-vsock/releases/latest/download/gvproxy-linux-amd64" (bin <> "/gvproxy")
  liftEffect (N.chmod (bin <> "/gvproxy") 493)
  C.prepareRuntime
  runtime <- C.bsdkrun
  void $ C.run runtime [ "--version" ]
  void $ C.run runtime [ "probe" ]
  before <- C.run runtime [ "docker", "status", "--json" ] >>= C.fromEither <<< C.jsonSuffix <<< _.stdout
  running <- C.fromEither (C.boolField "running" before)
  C.demand "CI installer needs a stopped or fresh engine; it will not reconfigure a running shared engine" (not running)
  void $ C.run runtime [ "docker", "start", "--cpus", "2", "--mem", "2048", "--publish-bind", "127.0.0.1", "--disk-size", "20G", "--json" ]
  let config = root <> "/daemon.json"
  liftEffect $ N.writeText config "{\"storage-driver\":\"vfs\",\"features\":{\"containerd-snapshotter\":false}}\n"
  void $ C.run runtime [ "exec", "bsdkrun-docker", "mkdir", "-p", "/etc/docker" ]
  void $ C.run runtime [ "cp", config, "bsdkrun-docker:/etc/docker/daemon.json" ]
  void $ C.run runtime [ "docker", "stop" ]
  void $ C.run runtime [ "docker", "start", "--publish-bind", "127.0.0.1", "--json" ]
  verifyDriver runtime
  filesystem <- C.run runtime [ "exec", "bsdkrun-docker", "stat", "-f", "-c", "%T", "/var/lib/docker" ]
  -- The driver, rather than the mere existence of data.img, is the CI
  -- compatibility guarantee. Record the mount after restarting as evidence.
  when (S.trim filesystem.stdout /= "ext2/ext3") $ liftEffect $ log "Docker image store is host-backed after restart; VFS avoids the unsupported overlay path."

download :: String -> String -> Aff Unit
download url destination = void $ C.run "curl" [ "--fail", "--show-error", "--silent", "--location", "--retry", "3", url, "-o", destination ]
