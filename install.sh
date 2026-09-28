#!/bin/bash
# Adds the Ultimate Brain Stimulation hooks to Claude Code (~/.claude/settings.json).
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$REPO/bin/ubs"
SETTINGS="$HOME/.claude/settings.json"
CONFIG_DIR="$HOME/.config/ultimate-brain-stimulation"

command -v jq >/dev/null || { echo "jq is required (brew install jq)." >&2; exit 1; }
chmod +x "$BIN"

mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/config" ]; then
  cp "$REPO/config.example" "$CONFIG_DIR/config"
  echo "Created $CONFIG_DIR/config"
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
# Keep the very first backup: it's the only one without our hooks in it.
[ -e "$SETTINGS.bak-ubs" ] || cp "$SETTINGS" "$SETTINGS.bak-ubs"

# Remove any earlier copy of our hooks (from any install path), then add them fresh.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
jq --arg cmd "'$BIN'" '
  def ours: (.command // "") | test("/bin/ubs[^ ]? (start|stop)( prompt)?$");
  def strip: map(.hooks |= map(select(ours | not))) | map(select(.hooks | length > 0));
  def put(event; arg):
    .hooks[event] = (((.hooks[event] // []) | strip)
      + [{hooks: [{type: "command", command: ($cmd + " " + arg), timeout: 10}]}]);
  .hooks = (.hooks // {})
  | put("UserPromptSubmit"; "start prompt")
  | put("PostToolUse"; "start")
  | put("Notification"; "stop")
  | put("Stop"; "stop")
  | put("SessionEnd"; "stop")
' "$SETTINGS" > "$tmp"
# Write through the file (not mv) so a symlinked settings.json and its permissions survive.
cat "$tmp" > "$SETTINGS"

echo "Hooks added to $SETTINGS (original backed up as $SETTINGS.bak-ubs)."
echo "Restart any open Claude Code sessions to pick them up."
