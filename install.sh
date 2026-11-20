#!/bin/sh
# Install a prebuilt duckdb-sbx release without Node.js or Bun.
set -eu

say() { printf '%s\n' "$*"; }
die() { printf 'duckdb-sbx install: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'HELP'
Usage: sh install.sh [VERSION]

Downloads the latest duckdb-sbx release, verifies SHA256SUMS, and installs
its executable to ~/.local/bin. VERSION may be v0.1.0 or 0.1.0.

Environment:
  DUCKDB_SBX_VERSION       Release to install (default: latest).
  DUCKDB_SBX_INSTALL_DIR   Binary directory (default: ~/.local/bin).

Requires curl, tar, and sha256sum or shasum. Running duckdb-sbx also needs
bsdkrun >= 0.12.1 and the Docker CLI for Linux guests.
HELP
}

[ "$#" -le 1 ] || die 'expected at most one version argument (use --help)'
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

version=${1:-${DUCKDB_SBX_VERSION:-latest}}
case "$version" in
  latest) base='https://github.com/tsirysndr/duckdb-sbx/releases/latest/download' ;;
  *)
    case "$version" in v*) ;; *) version="v$version" ;; esac
    printf '%s\n' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' \
      || die 'expected a release version such as v0.1.0'
    base="https://github.com/tsirysndr/duckdb-sbx/releases/download/$version"
    ;;
esac

os=$(uname -s)
arch=$(uname -m)
case "$os:$arch" in
  Darwin:arm64|Darwin:aarch64) platform=darwin-aarch64 ;;
  Linux:x86_64|Linux:amd64) platform=linux-x86_64 ;;
  Linux:aarch64|Linux:arm64) platform=linux-arm64 ;;
  *) die "unsupported platform $os/$arch; releases support macOS Apple Silicon and Linux x86_64/ARM64" ;;
esac

for tool in curl tar mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done
if command -v sha256sum >/dev/null 2>&1; then
  checksum_tool=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  checksum_tool=shasum
else
  die 'sha256sum or shasum is required to verify the download'
fi

install_dir=${DUCKDB_SBX_INSTALL_DIR:-}
if [ -z "$install_dir" ]; then
  [ -n "${HOME:-}" ] || die 'set HOME or DUCKDB_SBX_INSTALL_DIR'
  install_dir="$HOME/.local/bin"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/duckdb-sbx-install.XXXXXXXX")
staged_file=''
cleanup() {
  [ -z "$staged_file" ] || rm -f "$staged_file"
  rm -rf "$work_dir"
}
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM

asset="duckdb-sbx-$platform.tar.gz"
download() {
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
    --max-time 180 "$base/$1" -o "$work_dir/$1" \
    || die "could not download $1 from $version; check that the release and platform asset are published"
}

say "Downloading duckdb-sbx ($version, $platform)..."
download "$asset"
download SHA256SUMS
expected=$(awk -v name="$asset" '$2 == name { print $1; count++ } END { if (count != 1) exit 1 }' "$work_dir/SHA256SUMS") \
  || die "SHA256SUMS must contain exactly one checksum for $asset"
printf '%s\n' "$expected" | grep -Eq '^[0-9a-fA-F]{64}$' || die 'invalid release checksum'
expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
if [ "$checksum_tool" = sha256sum ]; then
  actual=$(sha256sum "$work_dir/$asset" | awk '{ print $1 }')
else
  actual=$(shasum -a 256 "$work_dir/$asset" | awk '{ print $1 }')
fi
[ "$actual" = "$expected" ] || die "checksum mismatch for $asset; existing installation was not changed"

mkdir "$work_dir/extracted"
tar -xzf "$work_dir/$asset" -C "$work_dir/extracted" duckdb-sbx \
  || die "could not extract duckdb-sbx from $asset"
[ -f "$work_dir/extracted/duckdb-sbx" ] && [ ! -L "$work_dir/extracted/duckdb-sbx" ] \
  || die 'release archive must contain a regular duckdb-sbx executable'

mkdir -p "$install_dir"
[ ! -d "$install_dir/duckdb-sbx" ] || die "$install_dir/duckdb-sbx is a directory"
# Stage beside the destination so replacement is atomic even across filesystems.
staged_file=$(mktemp "$install_dir/.duckdb-sbx.XXXXXXXX")
cp "$work_dir/extracted/duckdb-sbx" "$staged_file"
chmod 755 "$staged_file"
mv -f "$staged_file" "$install_dir/duckdb-sbx"
staged_file=''
say "Installed duckdb-sbx to $install_dir/duckdb-sbx"
case ":${PATH:-}:" in
  *:"$install_dir":*) ;;
  *) say "Add this directory to your PATH: $install_dir" ;;
esac
say 'Run duckdb-sbx doctor to check bsdkrun and Docker prerequisites.'
