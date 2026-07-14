#!/usr/bin/env bash
set -euo pipefail

# Non-interactive install/remove mechanism for agent-helpers-jj.
# Consent + reporting live in the command markdown; this script is the tested
# mechanism. All targets come from $HOME so tests can override it.
#
# Usage: agent-helpers-install.sh {install|remove}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/jj-agent-helpers.sh"
TEMPLATE="$SCRIPT_DIR/../templates/jj-agent-helpers-claudemd.md"

HELPER_DIR="$HOME/.config/jj-agent-helpers"
HELPER_PATH="$HELPER_DIR/jj-agent-helpers.sh"
ZSHRC="$HOME/.zshrc"
CLAUDEMD="$HOME/.claude/CLAUDE.md"
SETTINGS="$HOME/.claude/settings.json"

Z_BEGIN="# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>"
Z_END="# <<< jj-agent-helpers <<<"
C_BEGIN="<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->"
C_END="<!-- END jj-agent-helpers -->"
ALLOW=("Bash(jjctx:*)" "Bash(jjstack:*)" "Bash(jjconflicts:*)" "Bash(jjcheckpoint:*)")

# strip_fence FILE BEGIN END — remove the fenced block and one preceding blank line
strip_fence() {
  local file="$1" begin="$2" end="$3" bl el start
  [ -f "$file" ] || return 0
  grep -qxF "$begin" "$file" || return 0
  bl=$(grep -nxF "$begin" "$file" | head -1 | cut -d: -f1)
  el=$(grep -nxF "$end"   "$file" | head -1 | cut -d: -f1)
  { [ -n "$bl" ] && [ -n "$el" ] && [ "$el" -ge "$bl" ]; } || return 0
  start="$bl"
  if [ "$bl" -gt 1 ] && [ -z "$(sed -n "$((bl-1))p" "$file")" ]; then start=$((bl-1)); fi
  sed "${start},${el}d" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# append_block FILE BLOCK — ensure trailing newline + one blank separator, then append BLOCK
append_block() {
  local file="$1" block="$2"
  if [ -s "$file" ]; then
    [ "$(tail -c1 "$file" | wc -l)" -eq 1 ] || printf '\n' >> "$file"
    printf '\n' >> "$file"
  else
    : > "$file"
  fi
  printf '%s\n' "$block" >> "$file"
}

settings_json_array() { printf '%s\n' "${ALLOW[@]}" | jq -R . | jq -s .; }

settings_add() {
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq --argjson add "$(settings_json_array)" '
    .permissions = (.permissions // {})
    | .permissions.allow = ((.permissions.allow // []) as $cur
        | $cur + [ $add[] | select(. as $x | ($cur | index($x)) | not) ])
  ' "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
}

settings_remove() {
  [ -f "$SETTINGS" ] || return 0
  jq --argjson rm "$(settings_json_array)" '
    (if (.permissions.allow // null) != null then .permissions.allow -= $rm else . end)
    | (if (.permissions.allow == []) then del(.permissions.allow) else . end)
    | (if (.permissions == {}) then del(.permissions) else . end)
  ' "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
}

cmd_install() {
  mkdir -p "$HELPER_DIR"
  cp "$SRC" "$HELPER_PATH"
  strip_fence "$ZSHRC" "$Z_BEGIN" "$Z_END"
  append_block "$ZSHRC" "$(printf '%s\nsource %s\n%s' "$Z_BEGIN" "$HELPER_PATH" "$Z_END")"
  mkdir -p "$(dirname "$CLAUDEMD")"
  strip_fence "$CLAUDEMD" "$C_BEGIN" "$C_END"
  append_block "$CLAUDEMD" "$(cat "$TEMPLATE")"
  settings_add
}

cmd_remove() {
  strip_fence "$ZSHRC" "$Z_BEGIN" "$Z_END"
  strip_fence "$CLAUDEMD" "$C_BEGIN" "$C_END"
  settings_remove
  rm -f "$HELPER_PATH"
  rmdir "$HELPER_DIR" 2>/dev/null || true
}

case "${1:-}" in
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) echo "usage: $0 {install|remove}" >&2; exit 2 ;;
esac
