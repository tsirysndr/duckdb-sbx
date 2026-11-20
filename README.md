# duckdb-sbx

DuckDB in a [bsdkrun](https://github.com/tsirysndr/bsdkrun) microVM, with a
ZFS database branch you can fork copy-on-write, switch between, and delete.
Written in PureScript, following [postgres-sbx](../postgres-sbx),
[mariadb-sbx](../mariadb-sbx), and [sqlite-sbx](../sqlite-sbx).

```sh
duckdb-sbx start                       # Linux, DuckDB 2.0.0
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

DuckDB opens a file in the guest. There is no listening server, host port,
password, or Drizzle integration. `url` reports the file's location **inside
the guest**; it is not a host connection URL. The interactive CLI includes
completion and syntax highlighting; `sql` and `cli` also open it.

## Requirements and installation

- macOS on Apple Silicon, or Linux with KVM.
- [bsdkrun](https://github.com/tsirysndr/bsdkrun#install) 0.12 or newer
  (`brew install tsirysndr/tap/bsdkrun` on macOS).
- Node.js 22 or newer.
- For Linux guests, the Docker CLI (`brew install docker` on macOS).
  Docker Desktop is unnecessary: bsdkrun supplies the engine VM.
- Network access on first start for images or official BSD packages.

```sh
npm install                          # installs dependencies and builds PureScript
npm link
duckdb-sbx doctor
duckdb-sbx start
```

The bsdkrun PureScript SDK is pinned in `spago.yaml`; no sibling checkout is
required. To build a standalone executable with Bun:

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
| `duckdb` | Open the SQL shell (`sql`, `cli` also work) |
| `exec CMD...` | Run a command in the guest; `-t` allocates a terminal |
| `ssh` | Open a shell in the guest (alias: `shell`) |
| `log [-f]` | Show guest logs (alias: `logs`); `--boot` shows VM boot logs |
| `branch [NAME]` | List branches or fork the current one |
| `branch NAME --from SOURCE` | Fork another branch without switching |
| `branch -d NAME` | Delete a branch (`branch rm NAME` also works) |
| `checkout [-b] NAME` | Switch branches; `-b` creates first (alias: `switch`) |
| `url` | Print the file location in the guest |
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

The database file is created when a client first opens it. The default name is
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
CA certificates and the C++ runtime. The container idles with `sleep infinity`;
SQL clients run through `docker exec`. Custom image references are accepted
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
duckdb-sbx exec duckdb /var/lib/duckdb/duckdb.duckdb -c 'SELECT 42;'
# FreeBSD
duckdb-sbx exec /usr/local/bin/duckdb /var/lib/duckdb/duckdb.duckdb -c 'SELECT 42;'
# NetBSD
duckdb-sbx exec /usr/pkg/bin/duckdb /var/lib/duckdb/duckdb.duckdb -c 'SELECT 42;'

# Stream an input file into any guest
duckdb-sbx exec sh -c 'cat > /var/lib/duckdb/input.csv' < input.csv
```

Files under `/var/lib/duckdb` belong to the branch. On Linux, other container
files disappear when it is recreated; extensions installed in the container's
home may need reinstalling after checkout. BSD root-disk files persist but
are shared across data branches. Use absolute paths for imported files.

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
Docker nor Python tools for an existing BSD sandbox. `log -f` shows guest logs;
the Linux container normally has none. Use `log --boot` for VM startup issues.
NetBSD may reboot once to grow its root disk and once to load ZFS modules;
startup handles both. Provisioning errors include the package manager output.

## Live validation

On 2026-11-20, using macOS/arm64 and bsdkrun 0.12.0:

| Guest | Live result |
| --- | --- |
| FreeBSD 14.3 | Booted, mounted ZFS, installed official DuckDB 1.5.6, and returned 42 from a SQL query |
| NetBSD 11.99.11 (current) | Booted, resized the root disk, loaded ZFS after reboot, mounted the branch, and queried official DuckDB 1.5.5's version |
| NetBSD 10.1 | bsdkrun's kernel download URL returned HTTP 404 before boot |

Both installed packages were correctly rejected by the DuckDB >= 2 startup
check, so an end-to-end BSD sandbox with DuckDB >= 2 remains unverified.
NetBSD current also triggered Hypervisor.framework panics during shutdown;
bsdkrun eventually stopped the VM through its timeout fallback. The live run
exposed and fixed delayed detection of staged NetBSD ZFS modules when the
initial boot hook does not write a host readiness marker. All temporary test
VMs and data volumes were removed; the existing Docker engine was preserved.

## Development

```sh
npm run build
npm test
npm run build:bin
```

Tests cover profiles, OS parsing, VM/container creation arguments, version
guards and lifecycle/branch switching with mocked bsdkrun/Docker commands.
They include package failures, old BSD packages and NetBSD reboots; they do
not boot real VMs. A live smoke test on a fresh sandbox is:

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
