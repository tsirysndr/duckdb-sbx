# duckdb-sbx
[![Test](https://github.com/tsirysndr/duckdb-sbx/actions/workflows/test.yml/badge.svg)](https://github.com/tsirysndr/duckdb-sbx/actions/workflows/test.yml)

DuckDB in a [bsdkrun](https://github.com/tsirysndr/bsdkrun) microVM, with a
ZFS database branch you can fork copy-on-write, switch between, and delete.

```sh
duckdb-sbx start                       # Linux, DuckDB 2.0.0 Quack server on 127.0.0.1:9494
duckdb-sbx duckdb                      # interactive SQL shell; .quit to leave
duckdb-sbx checkout -b experiment      # fork main and switch
duckdb-sbx duckdb                      # query or change the fork
duckdb-sbx checkout main               # return to the original database
duckdb-sbx branch -d experiment
```

Linux runs a container in bsdkrun's shared Docker engine VM. FreeBSD and NetBSD
use dedicated VMs with DuckDB from their official package repositories.
Choose the guest on first start:

```sh
duckdb-sbx start linux 2.0.0           # VERSION is a DuckDB image tag
duckdb-sbx start freebsd               # latest FreeBSD release, pkg install duckdb
duckdb-sbx start freebsd 15.1          # VERSION is the FreeBSD release
duckdb-sbx start netbsd 10.1           # VERSION is the NetBSD release, pkg_add duckdb
```

These are alternatives for the same sandbox. Once created, its OS and version
are fixed; subsequent `start` calls resume it. `destroy` removes its data, so
export anything you need before recreating it with a different OS or version.

**DuckDB 2 or newer is required on every guest.** Linux defaults to `2.0.0` and
rejects older numeric image tags before creating resources. Startup checks the
actual CLI version, including custom images and BSD packages. If a BSD binary
repository supplies an older package, startup stops the VM and reports the
version. Update the guest's package repository/package, then rerun `start`.
The tool does not build DuckDB from source or silently accept an older version.
Package availability varies with the OS release, architecture and repository.

On Linux, the server owns the database file and exposes the **Quack remote
protocol**, authenticated with a password/token. The host listener binds only
to `127.0.0.1`. BSD guests retain embedded file access and do not accept
`--port` or `--password`. There is no Drizzle integration.

## Linux server and connections

```sh
duckdb-sbx start --password 'my-development-password'
duckdb-sbx start --port 19494 --password 'another-password'  # rotate and/or change port
duckdb-sbx url                         # quack:127.0.0.1:19494
duckdb-sbx token                       # print the current password/token
duckdb-sbx duckdb                      # authenticated SQL shell
duckdb-sbx duckdb -c 'SELECT version(), 42;'
duckdb-sbx sql -csv -c 'SELECT 42;'     # aliases also forward CLI arguments
```

`--password` accepts at least four characters and is the Quack authentication
token, not a SQL user's password. If omitted on first start, a random 256-bit
hex token is generated. Subsequent starts reuse it; setting `--password` again
recreates the server with the new token and preserves the database. The token
stays the same across branch checkouts. Port changes also recreate the server
without discarding data. Omitting `--port` reuses the recorded port, initially
9494. Startup rejects a conflicting port before replacing the existing server.
Readiness checks both an authenticated SQL query and the host listener. If an
existing engine publishes beyond loopback, startup removes the server and
reports how to restart that engine with `--publish-bind 127.0.0.1`.

The password is kept in the local state file with mode `0600`, and supplied to
the container through its environment. Server/client scripts read it with
`getenv`, so quotes in a password do not become SQL text. Logs, status and the
connection URI do not print it; `token` prints it explicitly.

To connect from a **DuckDB 2 or newer CLI on the host**, use the URI from `url`
and the token from `token`. For the default port:

```sh
export DUCKDB_SBX_PASSWORD="$(duckdb-sbx token)"
duckdb :memory: -cmd "ATTACH 'quack:127.0.0.1:9494' AS sbx (TOKEN getenv('DUCKDB_SBX_PASSWORD')); CONNECT sbx;"
```

`CONNECT sbx` routes subsequent SQL to the server, so ordinary `CREATE TABLE`,
`INSERT` and `SELECT` operate on the mounted branch. This uses Quack over HTTP
on local loopback, not the PostgreSQL wire protocol. See the
[Quack overview](https://duckdb.org/docs/2.0/quack/overview). The bundled
`duckdb-sbx duckdb` command uses a client in the container and needs no host
DuckDB installation. It connects through Quack rather than opening the file.

Existing Linux file-only sandboxes migrate on the next `start`: port 0 becomes
9494, an empty password is replaced with a generated token, and the container
is recreated over the existing data branch.

## Requirements and installation

- macOS on Apple Silicon, or Linux with KVM.
- [bsdkrun](https://github.com/tsirysndr/bsdkrun#install) 0.12.1 or newer
  (`brew install tsirysndr/tap/bsdkrun` on macOS).
- For Linux guests, the Docker CLI (`brew install docker` on macOS).
  Docker Desktop is unnecessary: bsdkrun supplies the engine VM.
- Network access on first start for images or official BSD packages.

### Homebrew

```sh
brew install tsirysndr/tap/duckdb-sbx
duckdb-sbx doctor
duckdb-sbx start linux 2.0.0
```

The formula installs bsdkrun and the Docker CLI as dependencies.

### Install script

```sh
curl -fsSL https://raw.githubusercontent.com/tsirysndr/duckdb-sbx/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
duckdb-sbx doctor
duckdb-sbx start linux 2.0.0
```

The installer downloads the latest release for macOS Apple Silicon, Linux
x86_64 or Linux ARM64, verifies it against the release's `SHA256SUMS`, and
installs to `~/.local/bin`. Prebuilt binaries need neither Node.js nor Bun.
Install bsdkrun and the Docker CLI separately before starting a sandbox.
Add the PATH setting to your shell profile to keep it across sessions.

To select a release or installation directory:

```sh
curl -fsSL https://raw.githubusercontent.com/tsirysndr/duckdb-sbx/main/install.sh | sh -s -- v0.1.0
curl -fsSL https://raw.githubusercontent.com/tsirysndr/duckdb-sbx/main/install.sh | DUCKDB_SBX_INSTALL_DIR="$HOME/bin" sh
```

### From source

Requires Node.js 22 or newer.

```sh
npm install                          # installs dependencies and builds PureScript
npm link
duckdb-sbx doctor
duckdb-sbx start
```

The bsdkrun PureScript SDK is pinned in `spago.yaml`.
To build a standalone executable with Bun:

```sh
npm run build:bin                     # dist/duckdb-sbx
```

The binary still needs bsdkrun and, for Linux guests, the Docker CLI on the host.

## Commands

| Command | Purpose |
| --- | --- |
| `start [linux\|freebsd\|netbsd] [VERSION]` | Create or resume the sandbox |
| `stop` | Stop the container or cleanly shut down the BSD VM |
| `status` | Show the guest, branch and database file |
| `duckdb [ARGS...]` | Open the SQL shell or run CLI arguments (`sql`, `cli` also work) |
| `exec CMD...` | Run a command in the guest; `-t` allocates a terminal |
| `ssh` | Open a shell in the guest (alias: `shell`) |
| `log [-f]` | Show guest logs (alias: `logs`); `--boot` shows VM boot logs |
| `branch [NAME]` | List branches or fork the current one |
| `branch NAME --from SOURCE` | Fork another branch without switching |
| `branch -d NAME` | Delete a branch (`branch rm NAME` also works) |
| `checkout [-b] NAME` | Switch branches; `-b` creates first (alias: `switch`) |
| `url` | Print the Linux Quack URI, or the BSD file location |
| `token` | Print the Linux Quack password/token |
| `doctor` | Check host prerequisites and sandbox state |
| `destroy [--yes]` | Remove the guest, data volume, all branches and state |

Every command has `--help`. `destroy` asks for confirmation unless `--yes`
is supplied. It preserves the shared engine VM and other sandbox containers.

```sh
duckdb-sbx start --db analytics       # /var/lib/duckdb/analytics.duckdb
duckdb-sbx start --size 20G           # sparse data volume, on first creation
duckdb-sbx start --branch staging     # mount an existing branch
duckdb-sbx start -d                   # skip streaming startup logs
```

The database file is created at Linux server startup, or on first client use
on BSD. The default name is
`duckdb`; names accept letters, digits, underscores and hyphens. The database
name is recorded on first start and reused afterward.

For BSD guests, `--cpus` (default 2) and `--mem` (default 1024 MiB) configure the
VM. Changing them restarts the VM. Its root disk grows to 10G to accommodate
packages; the data lives on the separate ZFS volume. Packages persist across
restarts and checkouts. FreeBSD uses `pkg install -y duckdb`; NetBSD uses
`pkg_add duckdb` with the official binary repository for the guest's
architecture and major OS release. Package prefixes are added to client PATH.

On Linux, size the shared VM with `bsdkrun docker start --cpus N --mem MIB`.
`start --cpus` and `--mem` record preferences but do not limit the container.
Attaching a new ZFS volume requires restarting the engine VM once; its other
containers return through their restart policies.

The [official DuckDB Docker image](https://github.com/duckdb/duckdb-docker/blob/main/Dockerfile)
is distroless. A cached build copies its CLI into Debian Bookworm with a shell,
CA certificates and the C++ runtime. The container runs `duckdb -serve`, configured to listen on guest port 9494
with the selected password. Quack and httpfs extensions are installed into the
image at build time. A small Docker init process forwards shutdown signals;
stdin stays open so the CLI server remains alive without a terminal. SQL
clients run through `docker exec` and connect to this server. Custom image
references are accepted
if they contain a compatible CLI at `/duckdb`, like the official image.

## Branches and file access

```sh
duckdb-sbx branch staging             # fork without switching
duckdb-sbx checkout staging
duckdb-sbx checkout -b try-query
duckdb-sbx checkout main
duckdb-sbx branch rm try-query
```

Close your SQL shell and finish writes before creating or switching branches.
Switching recreates the Linux container or cleanly stops, remounts and restarts
the BSD VM, disconnecting its clients. A stopped BSD VM stays stopped after a
checkout. ZFS copies the whole branch, including the database and any WAL
files. DuckDB's file locking still applies: use one writer process at a time.
See [DuckDB concurrency](https://duckdb.org/docs/stable/connect/concurrency).
`main` and the mounted branch cannot be deleted.

For noninteractive queries, `exec` binds stdin/stdout/stderr. BSD package paths
are explicit in these examples because arbitrary `exec` commands use the
agent's PATH:

```sh
# Linux
duckdb-sbx duckdb -c 'SELECT 42;'
# FreeBSD
duckdb-sbx exec /usr/local/bin/duckdb /var/lib/duckdb/duckdb.duckdb -c 'SELECT 42;'
# NetBSD
duckdb-sbx exec /usr/pkg/bin/duckdb /var/lib/duckdb/duckdb.duckdb -c 'SELECT 42;'

# Stream an input file into any guest
duckdb-sbx exec sh -c 'cat > /var/lib/duckdb/input.csv' < input.csv
```

Files under `/var/lib/duckdb` belong to the branch. On Linux, other container
files disappear when it is recreated; extra extensions installed after the
runtime image was built may need reinstalling after checkout. BSD root-disk files persist but
are shared across data branches. Use absolute paths for imported files.
On Linux, use the Quack client for
queries; opening the server's database file in another process will conflict
with its file lock.

## State and troubleshooting

| Location | Contents |
| --- | --- |
| `~/.config/duckdb-sbx/state.json` | OS, version, database name, branch and resources |
| `~/.config/duckdb-sbx/runtime/Dockerfile` | Generated Linux runtime image definition |
| `/mnt/duckdb-sbx-BRANCH` in the Linux engine VM | ZFS branch mountpoint |
| `/var/lib/duckdb` in the container or BSD VM | Mounted data branch |
| `/var/lib/duckdb/NAME.duckdb` in the guest | Database file |
| `bsdkrun zfs ls duckdb-sbx` | Data volume and branches |

`XDG_CONFIG_HOME` overrides `~/.config`. `doctor` checks bsdkrun, the
hypervisor and Node, plus Docker for a Linux sandbox. It requires neither
Docker nor Python tools for an existing BSD sandbox. `log -f` shows guest logs,
including Linux Quack startup failures. Use `log --boot` for VM startup issues.
NetBSD may reboot once to grow its root disk and once to load ZFS modules;
startup handles both. Provisioning errors include the package manager output.

## Live validation

On 2026-11-20, using macOS/arm64 and bsdkrun 0.12.0:

| Guest | Live result |
| --- | --- |
| Linux / DuckDB 2.0.0 | Served Quack on host loopback; host-client SQL, wrong-password rejection, password/port changes, stop/start persistence and isolated ZFS branch writes passed |
| FreeBSD 14.3 | Booted, mounted ZFS, installed official DuckDB 1.5.6, and returned 42 from a SQL query |
| NetBSD 11.99.11 (current) | Booted, resized the root disk, loaded ZFS after reboot, mounted the branch, and queried official DuckDB 1.5.5's version |
| NetBSD 10.1 | bsdkrun's kernel download URL returned HTTP 404 before boot |

Both BSD packages were correctly rejected by the DuckDB >= 2 startup
check, so an end-to-end BSD sandbox with DuckDB >= 2 remains unverified.
NetBSD current also triggered Hypervisor.framework panics during shutdown;
bsdkrun eventually stopped the VM through its timeout fallback. The live run
exposed and fixed delayed detection of staged NetBSD ZFS modules when the
initial boot hook does not write a host readiness marker. All temporary test
VMs and data volumes were removed; the existing Docker engine was preserved.

## GitHub Actions and releases

The `Test` workflow runs on pushes to `main`, pull requests and manual dispatch,
on **ubuntu-latest**. It uses `fluentci-io/setup-fluentci@next` with FluentCI
0.17.8 and `setup-purescript@v0.2.0` to provision PureScript 0.15.16, Spago
1.0.5, Node 24.22.2 and Bun 1.4.3, then `npm ci` builds the project. Setup's typed
environment output is validated before exporting it to later GitHub steps.

The custom native Wasm test component lives in `.fluentci/test`. It invokes
PureScript CI commands in `src/Ci`: downloads and verifies official bsdkrun
v0.12.1 archives (including Linux libkrun libraries), installs gvproxy and enables
`/dev/kvm`. It does not create or format a Docker image store or pre-start an
engine. The live suite exercises normal `duckdb-sbx start` from a fresh engine,
checks native overlay storage on ext4, restarts the VM and verifies persistence.
Missing KVM fails rather than skipping. Diagnostics record actual mounts,
engine status and guest process limits.

Normal startup requests a sparse 20 GiB image-store disk when creating a new
shared engine. bsdkrun 0.12.1 handles guest formatting and mounting; its ext4
zeroout fix removes the need for the old CI host-formatting workaround. Existing
engines keep their configuration and data. CI also uses bsdkrun's own host file
limit handling instead of changing process limits itself.

`npm test` runs PureScript assertions and **Bun tests** for mocked CLI lifecycles,
CI environment validation, release guards and executable headers. Live tests are
opt-in and also run under `bun test`:

```sh
fluentci run test unit                  # PureScript assertions and Bun tests
fluentci run --workflow test            # full Ubuntu CI; requires sudo and KVM
npm run build:bin
npm run test:e2e                        # Bun live suite; installed bsdkrun required
```

The PureScript E2E runner uses a unique sandbox name, tests authenticated host
SQL, incorrect passwords, port collisions, ZFS branch isolation, quoted password
rotation, port changes and stop/start persistence. Aff finalizers remove its own
container, volume and temporary configuration, including on interruption. It
preserves an existing engine and stops one it started only when no other
containers are running. Logs and a machine-readable result are retained for
seven days even on failure; passwords and state files are excluded. Commands
stream their output through stderr so FluentCI does not buffer progress, with
a heartbeat every 15 seconds during silent waits. Initial cold-image startup
is bounded to ten minutes; other commands keep their explicit shorter limits.
Timeouts settle even if a detached descendant retains an output pipe.

Installation, E2E assertions/cleanup, release packaging/publishing and GitHub
environment validation live in `src/Ci/*.purs`. There are no Bash CI scripts.
`Ci.Native` contains the Node FFI for processes, files, ports and signals; the
small `bin/bootstrap-ci.mjs` applies setup's environment to `npm ci` before the
first PureScript build. The compiled PureScript code then validates and exports
that environment to GitHub. FluentCI's SDK bootstrap/componentization stays in
the SDK's Node build entrypoints. Generated SDK and Wasm files are ignored.
See [.fluentci/test](.fluentci/test/README.md).

Push a tag matching `package.json` and `Main.version` (for example `v0.1.0`) to
run `Release`, or dispatch it manually with an existing matching tag. The release
workflow first runs the complete test workflow on that tag's source, then uses
the same PureScript setup and Bun cross-compilation to generate:

| Asset | Target |
| --- | --- |
| `duckdb-sbx-darwin-aarch64.tar.gz` | macOS Apple Silicon |
| `duckdb-sbx-linux-x86_64.tar.gz` | Linux x86_64, baseline CPU target |
| `duckdb-sbx-linux-arm64.tar.gz` | Linux ARM64 |

Each archive includes the executable, README and MIT license. Builds verify the
executable's architecture and release version before uploading artifacts. Only
after all targets succeed does a separate job with `contents: write` create or
update the GitHub release and upload all three archives plus `SHA256SUMS`.
GitHub's automatic token is sufficient; no repository secrets are required.
The binaries still require bsdkrun (and Docker for Linux guests) on the user host.

To build and verify a release archive locally without publishing:

```sh
RELEASE_TAG=v0.1.0 RELEASE_PLATFORM=linux-x86_64 npm run build:release
```

## Development

```sh
npm run build
npm test
npm run build:bin
```

Tests cover profiles, OS parsing, VM/container creation arguments, version
guards and lifecycle/branch switching with mocked bsdkrun/Docker commands.
They include port forwarding/collisions, password generation and rotation,
package failures, old BSD packages and NetBSD reboots. `npm test` does not boot
real VMs; the opt-in E2E command and the CI component do. A live smoke test on a fresh sandbox is:

```sh
duckdb-sbx start
# Open duckdb-sbx duckdb; run CREATE TABLE smoke AS SELECT 42 AS n; then .quit
duckdb-sbx checkout -b smoke
# Open duckdb-sbx duckdb; run UPDATE smoke SET n = 7; then .quit
duckdb-sbx checkout main
# Open duckdb-sbx duckdb; run SELECT * FROM smoke; -- expect 42
duckdb-sbx branch -d smoke
```

MIT license.
