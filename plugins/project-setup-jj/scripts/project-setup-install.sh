#!/usr/bin/env bash
set -euo pipefail

# project-setup-install.sh <plugin-root> <project-root>
# Deterministic installer for /project-setup (#78). No jj dependency.
# Copies the four consumer hook scripts, deep-merges hooks+permissions into
# <project-root>/.claude/settings.local.json (replace-by-identity at HOOK
# granularity; PreCompact by value; permissions union-deduped), installs/updates
# the CLAUDE.md section (4-case hash logic), and prints a key=value summary.
# Aborts without any side effect if an existing settings.local.json is invalid
# JSON. bash 3.2-safe.

PLUGIN_ROOT="${1:?usage: project-setup-install.sh <plugin-root> <project-root>}"
PROJECT_ROOT="${2:?usage: project-setup-install.sh <plugin-root> <project-root>}"

SRC="$PLUGIN_ROOT/scripts"
TEMPLATE="$PLUGIN_ROOT/templates/CLAUDE.md.template"
CLAUDE_DIR="$PROJECT_ROOT/.claude"
DST="$CLAUDE_DIR/scripts"
SETTINGS="$CLAUDE_DIR/settings.local.json"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"

# --- 0. fail-safe: validate an existing settings file BEFORE any side effect ---
# (must run before the copy loop so a malformed settings file aborts touching
# nothing on disk — not just leaving settings.local.json itself unchanged.)
if [ -f "$SETTINGS" ]; then
  if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    echo "ERROR: $SETTINGS exists but is not valid JSON; refusing to overwrite." >&2
    exit 1
  fi
  base=$(cat "$SETTINGS")
  settings_outcome="merged"
else
  base='{}'
  settings_outcome="created"
fi

# --- 1. dirs + copy the four consumer hook scripts ---
mkdir -p "$DST"
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  cp "$SRC/$s" "$DST/$s"
  chmod +x "$DST/$s"
done
echo "session_start=copied"
echo "require_jj_new=copied"
echo "workspace_hooks=copied"

# --- 2. settings.local.json merge ---
SS="$DST/jj-session-start.sh"
RJN="$DST/require-jj-new.sh"
WSC="$DST/jj-workspace-create.sh"
WSR="$DST/jj-workspace-remove.sh"

merged=$(printf '%s' "$base" | jq \
  --arg ss "$SS" --arg rjn "$RJN" --arg wsc "$WSC" --arg wsr "$WSR" '
  # hook-granularity replace-by-identity: strip hooks whose command ends with
  # $sfx from every entry of event $ev, drop emptied entries, append $new.
  def upsert($ev; $sfx; $new):
    .hooks[$ev] = (
      ((.hooks[$ev] // [])
        | map(.hooks = ((.hooks // []) | map(select((.command // "") | endswith($sfx) | not))))
        | map(select((.hooks // []) | length > 0)))
      + [$new]
    );
  def upsert_value($ev; $new):
    .hooks[$ev] = (((.hooks[$ev] // []) | map(select(. != $new))) + [$new]);

  ( .hooks //= {} )
  | upsert("SessionStart"; "/.claude/scripts/jj-session-start.sh";
      {matcher:"startup|resume|clear|compact", hooks:[{type:"command", command:$ss, async:false}]})
  | upsert("PreToolUse"; "/.claude/scripts/require-jj-new.sh";
      {matcher:"Edit|Write|NotebookEdit", hooks:[{type:"command", command:$rjn}]})
  | upsert("WorktreeCreate"; "/.claude/scripts/jj-workspace-create.sh";
      {hooks:[{type:"command", command:$wsc}]})
  | upsert("WorktreeRemove"; "/.claude/scripts/jj-workspace-remove.sh";
      {hooks:[{type:"command", command:$wsr}]})
  | upsert_value("PreCompact";
      {hooks:[{type:"command", command:"jj status >/dev/null 2>&1 || true"}]})
  | ( .permissions //= {} )
  | .permissions.allow = (((.permissions.allow // []) + [
      "Bash(jj status*)","Bash(jj diff*)","Bash(jj log*)","Bash(jj new*)",
      "Bash(jj commit*)","Bash(jj describe*)","Bash(jj bookmark*)","Bash(jj git push*)",
      "Bash(jj git fetch*)","Bash(jj rebase*)","Bash(jj squash*)","Bash(jj edit*)",
      "Bash(jj abandon*)","Bash(jj undo*)","Bash(jj op log*)","Bash(jj resolve*)",
      "Bash(jj root*)","Bash(jj file*)","Bash(jj split*)","Bash(jj config*)",
      "Bash(jj git remote*)","Bash(gh *)"
    ]) | unique)
  | .permissions.deny = (((.permissions.deny // []) + ["Bash(git *)"]) | unique)
  ')

mkdir -p "$CLAUDE_DIR"
printf '%s\n' "$merged" > "$SETTINGS"
echo "settings=$settings_outcome"

# --- 3. CLAUDE.md (4-case hash logic) ---
md5hash() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum; fi | cut -c1-8; }
tmpl_hash=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$TEMPLATE" | sed '1d;$d' | md5hash)

claude_outcome=""
if [ ! -f "$CLAUDE_MD" ]; then
  cp "$TEMPLATE" "$CLAUDE_MD"
  claude_outcome="created"
elif grep -q 'jj-project-setup:start' "$CLAUDE_MD"; then
  installed_hash=$(grep -o 'jj-project-setup:start hash:[0-9a-f]*' "$CLAUDE_MD" | head -1 | sed 's/.*hash://')
  if [ -n "$installed_hash" ] && [ "$installed_hash" = "$tmpl_hash" ]; then
    claude_outcome="unchanged"
  else
    s_line=$(grep -n 'jj-project-setup:start' "$CLAUDE_MD" | head -1 | cut -d: -f1)
    e_line=$(grep -n 'jj-project-setup:end' "$CLAUDE_MD" | head -1 | cut -d: -f1)
    { sed -n "1,$((s_line-1))p" "$CLAUDE_MD"; cat "$TEMPLATE"; sed -n "$((e_line+1)),\$p" "$CLAUDE_MD"; } > "$CLAUDE_MD.tmp"
    mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
    claude_outcome="updated"
  fi
else
  { cat "$TEMPLATE"; echo; cat "$CLAUDE_MD"; } > "$CLAUDE_MD.tmp"
  mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
  claude_outcome="updated"
fi
echo "claude_md=$claude_outcome"

echo "restart_required=true"
