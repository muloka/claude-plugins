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
# Project hook handlers live in .claude/hooks/ — the location every example in
# the Claude Code hooks docs uses. Nothing auto-discovers it (hooks are always
# registered in a settings file), so this is convention rather than mechanism,
# but it is the convention every reader arrives with. LEGACY_DST is where this
# installer used to put them; it is migrated from, never written to.
DST="$CLAUDE_DIR/hooks"
LEGACY_DST="$CLAUDE_DIR/scripts"
SETTINGS="$CLAUDE_DIR/settings.local.json"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"

# The four handlers this installer owns. Named once: the copy loop, the settings
# upsert identities, and the legacy cleanup must never disagree about the set.
MANAGED_SCRIPTS="jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh"

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
for s in $MANAGED_SCRIPTS; do
  cp "$SRC/$s" "$DST/$s"
  chmod +x "$DST/$s"
done
echo "session_start=copied"
echo "require_jj_new=copied"
echo "workspace_hooks=copied"

# --- 2. settings.local.json merge ---
# Hook commands are written $CLAUDE_PROJECT_DIR-relative rather than as absolute
# paths. An absolute /Users/... path is machine-specific: it pins the settings file
# to one checkout, so it cannot be shared with collaborators and breaks in any clone
# or jj workspace living at a different path. Claude Code expands
# $CLAUDE_PROJECT_DIR to the project root when the hook runs.
# The endswith() upsert below matches on the shared suffix, so re-running the
# installer over a pre-existing absolute-path entry replaces it in place instead of
# leaving a duplicate (covered by the "stale" case in test-project-setup-install.sh).
#
# The upsert strips a LIST of suffixes, not one. Handlers moved from
# .claude/scripts/ to .claude/hooks/, and a project installed before that move
# carries a registration under the OLD path. If identity were matched on the new
# suffix alone, that old registration would not match, would survive untouched,
# and the fresh entry would be appended beside it — leaving TWO registrations per
# event, both of which fire. Listing the legacy suffix alongside the current one
# makes a single run REPLACE the old registration instead of joining it.
HOOK_DIR='$CLAUDE_PROJECT_DIR/.claude/hooks'
SS="$HOOK_DIR/jj-session-start.sh"
RJN="$HOOK_DIR/require-jj-new.sh"
WSC="$HOOK_DIR/jj-workspace-create.sh"
WSR="$HOOK_DIR/jj-workspace-remove.sh"

merged=$(printf '%s' "$base" | jq \
  --arg ss "$SS" --arg rjn "$RJN" --arg wsc "$WSC" --arg wsr "$WSR" '
  # hook-granularity replace-by-identity: strip hooks whose command ends with ANY
  # suffix in $sfxs from every entry of event $ev, drop emptied entries, append
  # $new. $sfxs carries both the current .claude/hooks/ path and the legacy
  # .claude/scripts/ one, so a project on either layout ends with exactly one
  # registration rather than one per layout it has ever been installed under.
  def upsert($ev; $sfxs; $new):
    .hooks[$ev] = (
      ((.hooks[$ev] // [])
        | map(.hooks = ((.hooks // []) | map(
            . as $h | select($sfxs | any(. as $s | ($h.command // "") | endswith($s)) | not))))
        | map(select((.hooks // []) | length > 0)))
      + [$new]
    );
  def upsert_value($ev; $new):
    .hooks[$ev] = (((.hooks[$ev] // []) | map(select(. != $new))) + [$new]);

  ( .hooks //= {} )
  | upsert("SessionStart";
      ["/.claude/hooks/jj-session-start.sh", "/.claude/scripts/jj-session-start.sh"];
      {matcher:"startup|resume|clear|compact", hooks:[{type:"command", command:$ss, async:false}]})
  | upsert("PreToolUse";
      ["/.claude/hooks/require-jj-new.sh", "/.claude/scripts/require-jj-new.sh"];
      {matcher:"Edit|Write|NotebookEdit", hooks:[{type:"command", command:$rjn}]})
  | upsert("WorktreeCreate";
      ["/.claude/hooks/jj-workspace-create.sh", "/.claude/scripts/jj-workspace-create.sh"];
      {hooks:[{type:"command", command:$wsc}]})
  | upsert("WorktreeRemove";
      ["/.claude/hooks/jj-workspace-remove.sh", "/.claude/scripts/jj-workspace-remove.sh"];
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

# --- 3. legacy cleanup: retire .claude/scripts/ ---
# Runs AFTER the settings write, deliberately. Until settings point at the new
# location, the old files are still the live handlers; deleting them first would
# leave a window where the registered command names a file that no longer exists.
#
# Only the four files this installer owns are removed, by name. `.claude/scripts/`
# is NOT ours exclusively — /statusline-jj-setup installs statusline-jj.sh there,
# and users may keep their own scripts alongside. A blanket `rm -rf` would delete
# a file installed by a different command, silently breaking a statusline the
# person never asked this command to touch.
#
# The directory itself goes only when it is empty, and `rmdir` is what enforces
# that: it refuses on a non-empty directory, so the emptiness check and the
# removal are the same atomic operation. A test-then-remove would race, and a
# `-rf` would not check at all.
legacy_outcome="absent"
if [ -d "$LEGACY_DST" ]; then
  for s in $MANAGED_SCRIPTS; do
    rm -f "$LEGACY_DST/$s"
  done
  if rmdir "$LEGACY_DST" 2>/dev/null; then
    legacy_outcome="removed"
  else
    legacy_outcome="kept_not_empty"
  fi
fi
echo "legacy_scripts=$legacy_outcome"

# --- 4. CLAUDE.md (4-case hash logic) ---
md5hash() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum; fi | cut -c1-8; }
tmpl_hash=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$TEMPLATE" | sed '1d;$d' | md5hash)

# Markers are matched by "this LINE is a marker", never by "this line mentions
# the marker". A plain substring search treats prose such as
#   never edit inside the jj-project-setup:start block
# as the marker itself. When that sentence sits above the real block it becomes
# s_line, and everything from it down to the real end marker is replaced —
# silently destroying the prose and anything between. A real project documents
# the convention in exactly this way (just below its block rather than above),
# so the ordering that triggers it is one edit away.
#
# The template's own hash computation deliberately keeps the looser sed address
# it shares with tests/test-template-hash.sh: the template is repo-controlled
# and well-formed, and the two must agree byte-for-byte or the pin check breaks.
START_RE='^[[:space:]]*<!--[[:space:]]*jj-project-setup:start'
END_RE='^[[:space:]]*<!--[[:space:]]*jj-project-setup:end'

claude_outcome=""
if [ ! -f "$CLAUDE_MD" ]; then
  cp "$TEMPLATE" "$CLAUDE_MD"
  claude_outcome="created"
elif grep -qE "$START_RE" "$CLAUDE_MD"; then
  installed_hash=$(grep -E "$START_RE" "$CLAUDE_MD" | head -1 | grep -o 'hash:[0-9a-f]*' | sed 's/hash://')
  if [ -n "$installed_hash" ] && [ "$installed_hash" = "$tmpl_hash" ]; then
    claude_outcome="unchanged"
  else
    s_line=$(grep -nE "$START_RE" "$CLAUDE_MD" | head -1 | cut -d: -f1)
    e_line=$(grep -nE "$END_RE" "$CLAUDE_MD" | head -1 | cut -d: -f1)
    # The prefix slice must be skipped entirely when the marker is on line 1.
    # `sed -n "1,0p"` is an inverted range, and BSD sed prints line 1 for it
    # rather than nothing — which re-emitted the stale start marker above the
    # fresh one. The file then carried two start markers, and since the hash is
    # read from the FIRST one, every later run saw a stale hash and duplicated
    # the pair again. Observed in a real project before this guard existed.
    # The tail slice needs no such guard: `sed -n "N,\$p"` with N past the last
    # line correctly prints nothing.
    {
      [ "$s_line" -gt 1 ] && sed -n "1,$((s_line-1))p" "$CLAUDE_MD"
      cat "$TEMPLATE"
      sed -n "$((e_line+1)),\$p" "$CLAUDE_MD"
    } > "$CLAUDE_MD.tmp"
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
