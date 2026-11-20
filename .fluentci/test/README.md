# DuckDB sandbox test component

A PureScript native Wasm component for FluentCI **0.17.8**. The generated WIT
and help come from `src/Main.purs`; no Extism runtime is used.

```sh
fluentci run test all --help
fluentci run test all                        # Ubuntu x86_64, sudo and /dev/kvm
fluentci run test unit                       # any supported development host
fluentci run test e2e                        # installed bsdkrun, Docker and built dist/duckdb-sbx
```

`all` installs the pinned official bsdkrun release (default `v0.12.0`) and its
bundled Linux libkrun libraries plus gvproxy, enables access to `/dev/kvm`,
runs unit/mocked CLI tests, builds the native executable and runs the live
Quack/ZFS tests. Missing virtualization or networking tools fail the job;
there is no skip-success fallback.

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
