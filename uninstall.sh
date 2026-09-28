#!/bin/bash
# Removes the Ultimate Brain Stimulation hooks from Claude Code.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$REPO/bin/ubs"
SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null || { echo "jq is required (brew install jq)." >&2; exit 1; }
[ -f "$SETTINGS" ] || { echo "No $SETTINGS, nothing to do."; exit 0; }

"$BIN" reset >/dev/null 2>&1 || true
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
jq '
  def ours: (.command // "") | test("/bin/ubs[^ ]? (start|stop)( prompt)?$");
  if .hooks then
    .hooks |= (
      with_entries(.value |= (map(.hooks |= map(select(ours | not))) | map(select(.hooks | length > 0))))
      | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  else . end
' "$SETTINGS" > "$tmp"
cat "$tmp" > "$SETTINGS"

echo "Hooks removed from $SETTINGS."
echo "Your settings in ~/.config/ultimate-brain-stimulation were left in place."
