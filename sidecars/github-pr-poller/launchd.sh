#!/usr/bin/env bash
# Install, print or remove the macOS launchd job that runs poll.py on a timer.
#
#   ./launchd.sh install --repo acme/app --prefix MUL [more poll.py args]
#   ./launchd.sh print   --repo acme/app --prefix MUL   # show the plist only
#   ./launchd.sh uninstall
#
# INTERVAL (seconds, default 300) sets how often it runs.
set -euo pipefail

LABEL=local.multica-sidecars.github-pr-poller
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/multica-sidecars/github-pr-poller.log"
HERE="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${INTERVAL:-300}"

xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

plist() {
  local uv
  uv="$(command -v uv)" || { echo "uv not found on PATH" >&2; exit 1; }
  command -v gh >/dev/null || echo "warning: gh not found on PATH" >&2
  command -v multica >/dev/null || echo "warning: multica not found on PATH" >&2
  local args="" a
  for a in "$uv" run --script "$HERE/poll.py" "$@"; do
    args+="    <string>$(printf '%s' "$a" | xml_escape)</string>"$'\n'
  done
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(printf '%s' "$PATH" | xml_escape)</string>
  </dict>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  print)
    plist "$@" ;;
  install)
    [ $# -gt 0 ] || { echo "install needs poll.py args, e.g. --repo acme/app --prefix MUL" >&2; exit 2; }
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    plist "$@" > "$PLIST"
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "installed $PLIST; logs: $LOG" ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL (state in ~/.local/state/multica-sidecars/ is kept)" ;;
  *)
    sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
