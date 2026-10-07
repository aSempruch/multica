#!/usr/bin/env bash
# Build the multica CLI (which includes the daemon) from this checkout, instead
# of using the Homebrew tap or the GitHub release binaries. Runs on macOS and
# Linux, including inside a Linux container that has the checkout.
#
# Usage:
#   scripts/install-cli-from-source.sh [--bin-dir DIR]
#   scripts/install-cli-from-source.sh --output FILE [--target OS/ARCH]
#
# Options:
#   --bin-dir DIR      Install directory (default: $MULTICA_BIN_DIR or ~/.local/bin)
#   --output FILE      Only build, writing the binary to FILE; nothing is installed
#   --target OS/ARCH   Cross-build with --output, e.g. linux/amd64 or linux/arm64
#
# Needs bash, git and Go 1.21 or newer, taken from PATH or
# /usr/local/go/bin/go (on Alpine: apk add bash git). The script itself makes
# no network requests; `go build` fetches modules, and a newer toolchain if
# server/go.mod asks for one, through Go's own module proxy settings.
#
# The binary is stamped with a `git describe --long` version such as
# v0.6.1-2-gab586a87c. The daemon treats that shape as a source build and never
# auto-updates it to a public release; `multica update` or an update triggered
# from the Runtimes page still would, so rerun this script to upgrade instead.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/server"
BIN_DIR="${MULTICA_BIN_DIR:-$HOME/.local/bin}"
OUTPUT=""
TARGET=""

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

need_value() { [ "$2" -ge 2 ] || fail "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --bin-dir) need_value "$1" $#; BIN_DIR="$2"; shift 2 ;;
    --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
    --output) need_value "$1" $#; OUTPUT="$2"; shift 2 ;;
    --output=*) OUTPUT="${1#*=}"; shift ;;
    --target) need_value "$1" $#; TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown option: $1" ;;
  esac
done

[ -f "$SERVER_DIR/go.mod" ] || fail "$SERVER_DIR/go.mod not found; run this from a Multica checkout"

case "$(uname -s)" in
  Darwin)
    HOST_OS=darwin
    # Build for the hardware, not the shell: under Rosetta `uname -m` says x86_64.
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
      HOST_ARCH=arm64
    else
      HOST_ARCH=amd64
    fi
    ;;
  Linux)
    HOST_OS=linux
    case "$(uname -m)" in
      x86_64|amd64) HOST_ARCH=amd64 ;;
      aarch64|arm64) HOST_ARCH=arm64 ;;
      *) fail "unsupported Linux architecture: $(uname -m)" ;;
    esac
    ;;
  *) fail "unsupported OS: $(uname -s) (macOS and Linux only)" ;;
esac

TARGET_OS="$HOST_OS"
TARGET_ARCH="$HOST_ARCH"
if [ -n "$TARGET" ]; then
  TARGET_OS="${TARGET%%/*}"
  TARGET_ARCH="${TARGET#*/}"
  case "$TARGET_OS/$TARGET_ARCH" in
    darwin/amd64|darwin/arm64|linux/amd64|linux/arm64) ;;
    *) fail "--target must be darwin/amd64, darwin/arm64, linux/amd64 or linux/arm64" ;;
  esac
fi
if [ -z "$OUTPUT" ] && [ "$TARGET_OS/$TARGET_ARCH" != "$HOST_OS/$HOST_ARCH" ]; then
  fail "--target $TARGET_OS/$TARGET_ARCH can't run here; add --output FILE to only build it"
fi

if [ -n "$OUTPUT" ]; then
  case "$OUTPUT" in
    */) fail "--output must be a file path, not a directory" ;;
  esac
  [ ! -d "$OUTPUT" ] || fail "--output $OUTPUT is a directory; pass a file path"
  mkdir -p "$(dirname "$OUTPUT")"
  DEST="$(cd "$(dirname "$OUTPUT")" && pwd -P)/$(basename "$OUTPUT")"
else
  mkdir -p "$BIN_DIR"
  BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
  DEST="$BIN_DIR/multica"

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
fi

# --- Go toolchain -----------------------------------------------------------

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

GO_BIN="$(command -v go 2>/dev/null || true)"
[ -n "$GO_BIN" ] || GO_BIN=/usr/local/go/bin/go
[ -x "$GO_BIN" ] || fail "Go not found on PATH or at /usr/local/go/bin/go; install Go 1.21+ first"
go_is_usable "$GO_BIN" || fail "$GO_BIN is older than Go 1.21; install a newer Go"

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

# --- Build ------------------------------------------------------------------

info "Building multica $VERSION ($TARGET_OS/$TARGET_ARCH) with $("$GO_BIN" env GOVERSION)"

# Build next to the destination and rename into place. Rewriting a running
# binary in place fails on Linux (text file busy) and gets it killed by macOS
# code signing checks; a rename leaves the running copy untouched.
tmp_bin="$(mktemp "$(dirname "$DEST")/.multica.XXXXXX")"
trap 'rm -f "$tmp_bin"' EXIT

(
  cd "$SERVER_DIR"
  CGO_ENABLED=0 GOOS="$TARGET_OS" GOARCH="$TARGET_ARCH" "$GO_BIN" build \
    -trimpath \
    -ldflags "-s -w -X main.version=$VERSION -X main.commit=$COMMIT -X main.date=$DATE" \
    -o "$tmp_bin" ./cmd/multica
)
chmod 755 "$tmp_bin"
if [ "$TARGET_OS/$TARGET_ARCH" = "$HOST_OS/$HOST_ARCH" ]; then
  "$tmp_bin" version >/dev/null || fail "built binary failed to run"
fi
mv -f "$tmp_bin" "$DEST"
trap - EXIT

if [ -n "$OUTPUT" ]; then
  info "Built $DEST ($TARGET_OS/$TARGET_ARCH, $VERSION)"
  exit 0
fi

info "Installed $DEST"
"$DEST" version

# --- PATH checks ------------------------------------------------------------

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    warn "$BIN_DIR is not on PATH. Add this to your shell profile:"
    printf '    export PATH="%s:$PATH"\n' "$BIN_DIR" >&2
    ;;
esac

resolved="$(command -v multica 2>/dev/null || true)"
if [ -n "$resolved" ] && [ "$(cd "$(dirname "$resolved")" && pwd -P)/multica" != "$DEST" ]; then
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
