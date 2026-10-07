#!/usr/bin/env bash
# Build the multica CLI from this checkout and install it on macOS, instead of
# the Homebrew tap or the GitHub release binaries.
#
# Usage:
#   scripts/install-cli-from-source.sh [--bin-dir DIR]
#
# Options:
#   --bin-dir DIR   Install directory (default: $MULTICA_BIN_DIR or ~/.local/bin)
#
# Uses `go` from PATH when it is new enough to fetch the toolchain go.mod asks
# for (Go 1.21+). Otherwise it downloads that exact Go release from go.dev into
# ~/Library/Caches/multica-cli-source (checksum-verified), keeps its module and
# build caches there too, and builds with it. Delete that directory to undo it.
#
# The binary is stamped with a `git describe --long` version such as
# v0.6.1-2-gab586a87c. The daemon treats that shape as a source build and never
# auto-updates it to a public release; `multica update` or an update triggered
# from the Runtimes page still would, so rerun this script to upgrade instead.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"
CACHE_DIR="${MULTICA_SOURCE_CACHE_DIR:-$HOME/Library/Caches/multica-cli-source}"
BIN_DIR="${MULTICA_BIN_DIR:-$HOME/.local/bin}"

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir)
      [ $# -ge 2 ] || fail "--bin-dir needs a directory"
      BIN_DIR="$2"
      shift 2
      ;;
    --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || fail "this script only supports macOS"
[ -f "$SERVER_DIR/go.mod" ] || fail "$SERVER_DIR/go.mod not found; run this from a Multica checkout"

# Build for the hardware, not the shell: under Rosetta `uname -m` says x86_64.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
  GOARCH_HOST=arm64
else
  GOARCH_HOST=amd64
fi

mkdir -p "$BIN_DIR"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"

# A binary under the Homebrew prefix is treated as a brew install, so
# `multica update` would try `brew upgrade` on it.
if command -v brew >/dev/null 2>&1; then
  brew_prefix="$(brew --prefix 2>/dev/null || true)"
  if [ -n "$brew_prefix" ]; then
    brew_prefix="$(cd "$brew_prefix" 2>/dev/null && pwd -P || echo "$brew_prefix")"
    case "$BIN_DIR/" in
      "$brew_prefix"/*) fail "$BIN_DIR is inside the Homebrew prefix ($brew_prefix); choose another --bin-dir" ;;
    esac
  fi
fi

# --- Go toolchain -----------------------------------------------------------

go_mod_version() {
  local v
  v="$(awk '$1 == "go" { print $2; exit }' "$SERVER_DIR/go.mod")"
  [ -n "$v" ] || fail "could not read the go version from server/go.mod"
  # Go 1.21+ release archives always carry a patch number (go1.26.0).
  case "$v" in
    *.*.*) ;;
    *) v="$v.0" ;;
  esac
  printf '%s\n' "$v"
}

# True when this go can switch to the toolchain go.mod requires (Go 1.21+).
go_is_usable() {
  local v major minor
  v="$("$1" env GOVERSION 2>/dev/null)" || return 1
  v="${v#go}"
  major="${v%%.*}"
  minor="${v#*.}"
  minor="${minor%%[!0-9]*}"
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 21 ]; }
}

bootstrap_go() {
  local version="$1"
  local root="$CACHE_DIR/go$version-darwin-$GOARCH_HOST"
  if [ -x "$root/go/bin/go" ]; then
    printf '%s\n' "$root/go/bin/go"
    return
  fi

  local archive="go$version.darwin-$GOARCH_HOST.tar.gz"
  local url="https://dl.google.com/go/$archive"
  # Runs inside $(...), so this EXIT trap only cleans up the download
  # subshell. Not local: the trap fires after the function has returned.
  go_dl_tmp="$(mktemp -d)"
  trap 'rm -rf "$go_dl_tmp"' EXIT

  info "Go not found on PATH; downloading Go $version for building" >&2
  curl -fsSL "$url" -o "$go_dl_tmp/$archive" || fail "failed to download $url"
  curl -fsSL "$url.sha256" -o "$go_dl_tmp/sha256" || fail "failed to download $url.sha256"
  local expected actual
  expected="$(tr -d '[:space:]' <"$go_dl_tmp/sha256")"
  actual="$(shasum -a 256 "$go_dl_tmp/$archive" | awk '{ print $1 }')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] ||
    fail "checksum mismatch for $archive (expected $expected, got $actual)"

  mkdir -p "$go_dl_tmp/extract"
  tar -xzf "$go_dl_tmp/$archive" -C "$go_dl_tmp/extract"
  mkdir -p "$CACHE_DIR"
  rm -rf "$root"
  mv "$go_dl_tmp/extract" "$root"
  printf '%s\n' "$root/go/bin/go"
}

GO_BIN=""
if command -v go >/dev/null 2>&1 && go_is_usable "$(command -v go)"; then
  GO_BIN="$(command -v go)"
else
  command -v go >/dev/null 2>&1 && warn "$(command -v go) is older than Go 1.21; using a downloaded toolchain"
  GO_BIN="$(bootstrap_go "$(go_mod_version)")"
  # Keep the downloaded toolchain's module and build caches beside it rather
  # than creating ~/go and ~/Library/Caches/go-build.
  export GOPATH="$CACHE_DIR/gopath" GOCACHE="$CACHE_DIR/go-build"
fi

# --- Version stamp ----------------------------------------------------------

# --long keeps the describe shape (vX.Y.Z-N-gHASH) even on an exact tag, which
# both the daemon's auto-update and the server's version gates read as a source
# build. A bare tag would look like a release and be auto-updated away.
COMMIT="unknown"
if git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  if ! VERSION="$(git -C "$ROOT_DIR" describe --tags --long --match 'v[0-9]*' --dirty 2>/dev/null)"; then
    warn "no v* tags in this checkout (try: git fetch --tags); stamping v0.0.0"
    VERSION="v0.0.0-0-g$COMMIT"
    git -C "$ROOT_DIR" diff --quiet HEAD 2>/dev/null || VERSION="$VERSION-dirty"
  fi
else
  warn "not a git checkout; stamping v0.0.0"
  VERSION="v0.0.0-0-g0"
fi
DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# --- Build and install ------------------------------------------------------

info "Building multica $VERSION (darwin/$GOARCH_HOST) with $("$GO_BIN" env GOVERSION)"

# Build next to the destination and rename into place: replacing a running
# binary by rewriting it in place gets it killed by macOS code signing checks.
tmp_bin="$(mktemp "$BIN_DIR/.multica.XXXXXX")"
trap 'rm -f "$tmp_bin"' EXIT

(
  cd "$SERVER_DIR"
  CGO_ENABLED=0 GOOS=darwin GOARCH="$GOARCH_HOST" "$GO_BIN" build \
    -trimpath \
    -ldflags "-s -w -X main.version=$VERSION -X main.commit=$COMMIT -X main.date=$DATE" \
    -o "$tmp_bin" ./cmd/multica
)
chmod 755 "$tmp_bin"
"$tmp_bin" version >/dev/null || fail "built binary failed to run"
mv -f "$tmp_bin" "$BIN_DIR/multica"
trap - EXIT

info "Installed $BIN_DIR/multica"
"$BIN_DIR/multica" version

# --- PATH checks ------------------------------------------------------------

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not on PATH. Add it, e.g. in ~/.zshrc:"
    printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" >&2
    ;;
esac

resolved="$(command -v multica 2>/dev/null || true)"
if [ -n "$resolved" ] && [ "$(cd "$(dirname "$resolved")" && pwd -P)/multica" != "$BIN_DIR/multica" ]; then
  warn "'multica' on PATH resolves to $resolved, not this build."
  if command -v brew >/dev/null 2>&1 && brew list multica >/dev/null 2>&1; then
    warn "Remove the Homebrew copy with: brew uninstall multica"
  else
    warn "Remove that copy or put $BIN_DIR earlier on PATH."
  fi
fi

cat <<EOF

A daemon running from this path switches to the new binary by itself within
about 10 minutes, once it is idle and the version string has changed. A daemon
started from another copy (e.g. Homebrew) keeps running that copy. To switch
now, run: multica daemon restart
EOF
