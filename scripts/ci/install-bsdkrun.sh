#!/usr/bin/env bash
# Invoked by the custom FluentCI component, not by an unrelated setup action.
set -euo pipefail
version="${1:-v0.12.0}"
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected a bsdkrun release such as v0.12.0' >&2; exit 1; }
[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || { echo 'The installer requires Ubuntu x86_64 with KVM (ubuntu-latest).' >&2; exit 1; }
[[ -e /dev/kvm ]] || { echo '/dev/kvm is required; live tests are never skipped.' >&2; exit 1; }

sudo -n apt-get update
sudo -n apt-get install -y --no-install-recommends ca-certificates curl tar gzip xz-utils libgmp10 libtinfo6
# GitHub-hosted Ubuntu has KVM, but the runner user may not own the device.
sudo -n chmod a+rw /dev/kvm
[[ -r /dev/kvm && -w /dev/kvm ]]
command -v docker >/dev/null # GitHub's Ubuntu image provides the client.

export BSDKRUN_INSTALL="$PWD/.fluentci/tools/bsdkrun"
mkdir -p "$BSDKRUN_INSTALL"
curl --fail --show-error --silent --location --retry 3 \
  "https://raw.githubusercontent.com/tsirysndr/bsdkrun/$version/install.sh" \
  -o "$BSDKRUN_INSTALL/install.sh"
bash "$BSDKRUN_INSTALL/install.sh" "$version"
export PATH="$BSDKRUN_INSTALL/bin:$PATH"
command -v gvproxy >/dev/null # The upstream installer treats this download as optional; CI does not.
bsdkrun --version
bsdkrun probe
