# DuckDB sandbox test component

A PureScript native Wasm component for FluentCI **0.17.8**. The generated WIT
and help come from `src/Main.purs`; no Extism runtime is used.

```sh
fluentci run test all --help
fluentci run test all                        # Ubuntu x86_64, sudo and /dev/kvm
fluentci run test unit                       # any supported development host
fluentci run test e2e                        # installed bsdkrun, Docker and built dist/duckdb-sbx
```

`all` invokes the project's compiled PureScript CI runner (`src/Ci`). It
verifies the pinned bsdkrun release archive (default `v0.12.0`), installs its
bundled Linux libkrun libraries and gvproxy, and enables `/dev/kvm`. It requests
a sparse 20 GiB Docker data disk, formats its regular file on the host as ext4,
and requires native overlay storage (`overlayfs` or `overlay2`). This bypasses
in-guest formatting that can truncate the backing image by 64 KiB and break
ext4's geometry at the next boot. Driver and actual ext4 mount checks run before
and after a restart; VFS is rejected. Installation requires a fresh engine and
image store so existing data is never formatted.

E2E diagnostics capture post-ZFS mounts, engine status and guest process limits.
GitHub Linux processes raise both soft/hard open-file limits to the kernel
ceiling before starting VMs, preventing virtio-fs inode handle exhaustion.

It runs PureScript assertions and `bun test` for mocked CLI/CI checks, builds
the executable, then runs the opt-in Bun live suite. No Bash scripts are used.
The project's Node FFI only supplies process/filesystem/network primitives;
installation decisions, validations, assertions and cleanup are PureScript.
Missing virtualization/networking tools fail the job; tests are never skipped.

Use `--directory /path/to/duckdb-sbx` to select another checkout, or
`--bsdkrun-version vX.Y.Z` on `all` to deliberately change the runtime release.
The installer stores tools under the checkout's `.fluentci/tools/bsdkrun`.

The SDK is regenerated from the pinned CLI into ignored `.sdk/` by
`bootstrap.mjs`, then `build.mjs` uses the starter's locked npm/Spago tools to
compile the component. Commit the manifests, both lockfiles and authored
source. SDK copies, dependencies, generated WIT/metadata and Wasm output are
build artifacts. Run only one build/inspection command in this directory at
a time, as npm ci and componentization both replace generated files.

The live test uses a unique sandbox name and temporary configuration, removes
its own container and ZFS volume in `finally`, and preserves an already-running
engine. It stops an engine it started only when no other containers are
running. Logs and a machine-readable result go to `.fluentci/test-logs/`;
passwords and state files are excluded from diagnostics.

Command output streams to stderr to remain visible through FluentCI's stdout
capture. E2E prints redacted command lines and a heartbeat every 15 seconds.
Cold-image startup has a ten-minute limit; shorter per-command limits and
pipe-independent timeout handling keep failures bounded.
