#!/usr/bin/env bash
set -euo pipefail
if [[ -x "$PWD/.fluentci/tools/bsdkrun/bin/bsdkrun" ]]; then
  export BSDKRUN_BIN="$PWD/.fluentci/tools/bsdkrun/bin/bsdkrun"
  export PATH="$PWD/.fluentci/tools/bsdkrun/bin:$PATH"
fi
export BSDKRUN_NO_AUTO_INSTALL=1
node test/e2e.mjs
