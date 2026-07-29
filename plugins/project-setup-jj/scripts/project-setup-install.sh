#!/usr/bin/env bash
set -euo pipefail

# project-setup-install.sh [--local] <plugin-root> <project-root>
# Deterministic installer for /project-setup (#78). No jj dependency.
# Copies the four consumer hook scripts, deep-merges hooks+permissions into the
# project's settings (replace-by-identity at HOOK granularity; PreCompact by
# value; permissions union-deduped), installs/updates the CLAUDE.md section
# (4-case hash logic), and prints a key=value summary. Aborts without any side
# effect if an existing settings file is invalid JSON. bash 3.2-safe.
#
# WHERE THE SETTINGS GO (#97)
#
# Default is TRACKED: hooks and permissions.deny go to .claude/settings.json,
# which is meant to be committed. Everything personal — permissions.allow, and
# statusLine if /statusline-jj-setup is used — stays in settings.local.json.
#
# The reason is that untracked enforcement does not travel. A fresh clone, or a
# `jj workspace add` checkout, gets CLAUDE.md declaring the jj rules and none of
# the wiring that enforces them, so the rules are weakest exactly where
# workspace-jj:kaisen fans agents out in parallel. Tracked CLAUDE.md plus
# untracked enforcement is a declaration and a behaviour disagreeing.
#
# The two defaults also fail asymmetrically. Default-tracked fails VISIBLY: an
# unwanted settings.json shows up in `jj status` and is deleted in seconds.
# Default-local fails INVISIBLY, and nobody finds out until an agent runs raw
# git in a workspace that never had the wall.
#
# `--local` keeps the old behaviour — everything in settings.local.json, nothing
# written to a tracked path. It is the escape hatch for a repo you do not want to
# commit to, and for the `.gitignore` abort below.
#
# HOOKS MUST LIVE IN EXACTLY ONE FILE. Measured 2026-07-29: hooks registered at
# both project and local scope BOTH fire, once each — they merge additively
# rather than overriding, unlike most settings. So a tracked install must also
# STRIP the managed hooks out of settings.local.json, or every migrating project
# runs every handler twice. permissions.deny is the easy half: it merges by
# documented design and is union-deduped, so a duplicate there is harmless.

MODE="tracked"
POSITIONAL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --local) MODE="local"; shift ;;
    --) shift; break ;;
    -*) printf 'unknown option: %s\n' "$1" >&2
        printf 'usage: project-setup-install.sh [--local] <plugin-root> <project-root>\n' >&2
        exit 64 ;;
    *) POSITIONAL="$POSITIONAL $1"; shift ;;
  esac
done
# shellcheck disable=SC2086
set -- $POSITIONAL

PLUGIN_ROOT="${1:?usage: project-setup-install.sh [--local] <plugin-root> <project-root>}"
PROJECT_ROOT="${2:?usage: project-setup-install.sh [--local] <plugin-root> <project-root>}"

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
SETTINGS_TRACKED="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"

# The four handlers this installer owns. Named once: the copy loop, the settings
# upsert identities, and the legacy cleanup must never disagree about the set.
MANAGED_SCRIPTS="jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh"

# --- 0. fail-safe: validate existing settings files BEFORE any side effect ---
# (must run before the copy loop so a malformed settings file aborts touching
# nothing on disk — not just leaving the settings file itself unchanged.)
read_json_or_die() {
  if [ -f "$1" ]; then
    if ! jq empty "$1" >/dev/null 2>&1; then
      echo "ERROR: $1 exists but is not valid JSON; refusing to overwrite." >&2
      exit 1
    fi
    cat "$1"
  else
    printf '{}'
  fi
}

base=$(read_json_or_die "$SETTINGS")
if [ -f "$SETTINGS" ]; then settings_outcome="merged"; else settings_outcome="created"; fi

tracked_base='{}'
tracked_outcome="skipped"
if [ "$MODE" = "tracked" ]; then
  tracked_base=$(read_json_or_die "$SETTINGS_TRACKED")
  if [ -f "$SETTINGS_TRACKED" ]; then tracked_outcome="merged"; else tracked_outcome="created"; fi
fi

# --- 0b. tracked mode requires .gitignore not to exclude the .claude DIRECTORY ---
# git (and jj) cannot re-include a file whose parent directory is excluded, so a
# blanket `.claude/` makes `!.claude/settings.json` inert — measured on jj 0.43.0:
# with the blanket rule plus negations, NOTHING under .claude/ is tracked.
#
# That is why appending negations is not a fix, and why this aborts instead of
# rewriting: an append-only implementation would report success while changing
# nothing, leaving a fresh clone enforcing nothing — the same silent-success shape
# as #82. Rewriting a user's ignore rules is the most invasive thing this
# installer could do in someone else's repository, so it refuses and explains.
#
# Abort BEFORE the copy loop: no scripts, no settings, no CLAUDE.md edit.
if [ "$MODE" = "tracked" ] && [ -f "$PROJECT_ROOT/.gitignore" ]; then
  blanket=""
  while IFS= read -r gi_line || [ -n "$gi_line" ]; do
    gi_line="${gi_line%$'\r'}"
    # trim trailing whitespace; leading whitespace is not meaningful in gitignore
    while :; do
      case "$gi_line" in
        *' '|*"$(printf '\t')") gi_line="${gi_line%?}" ;;
        *) break ;;
      esac
    done
    case "$gi_line" in
      ''|'#'*) continue ;;
      # Every spelling that excludes the DIRECTORY itself. Matching only the
      # literal `.claude/` would let the same trap through in four other forms.
      '.claude/'|'.claude'|'/.claude/'|'/.claude'|'.claude/**'|'/.claude/**')
        blanket="$gi_line"; break ;;
    esac
  done < "$PROJECT_ROOT/.gitignore"

  if [ -n "$blanket" ]; then
    cat >&2 <<EOF
ERROR: .gitignore excludes the .claude directory ("$blanket"), so a tracked
       .claude/settings.json can never be committed. Nothing was changed.

Neither git nor jj can re-include a file whose parent directory is excluded, so
adding "!.claude/settings.json" below that line has no effect at all.

Replace the "$blanket" line with:

  .claude/*
  !.claude/settings.json
  !.claude/hooks/
  .claude/settings.local.json

Then re-run /project-setup. Or, to keep everything untracked as before:

  /project-setup --local
EOF
    exit 3
  fi
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

# Shared jq definitions. `upsert`/`upsert_value` add a registration; `strip`/
# `strip_value` remove one. Both directions are needed now that hooks may have to
# be moved OUT of settings.local.json rather than only into a file.
JQ_DEFS='
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
  # Removal counterparts. An event left with no entries is deleted rather than
  # left as an empty array, so a migrated local file does not accumulate hollow
  # keys that read as "this file registers hooks" to anyone inspecting it.
  def strip($ev; $sfxs):
    if (.hooks | type) == "object" then
      .hooks[$ev] = (((.hooks[$ev] // [])
        | map(.hooks = ((.hooks // []) | map(
            . as $h | select($sfxs | any(. as $s | ($h.command // "") | endswith($s)) | not))))
        | map(select((.hooks // []) | length > 0))))
      | (if ((.hooks[$ev] // []) | length) == 0 then del(.hooks[$ev]) else . end)
    else . end;
  def strip_value($ev; $v):
    if (.hooks | type) == "object" then
      .hooks[$ev] = (((.hooks[$ev] // []) | map(select(. != $v))))
      | (if ((.hooks[$ev] // []) | length) == 0 then del(.hooks[$ev]) else . end)
    else . end;
  def all_hooks: .
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
        {hooks:[{type:"command", command:"jj status >/dev/null 2>&1 || true"}]});
  def strip_all_hooks: .
    | strip("SessionStart";  ["/.claude/hooks/jj-session-start.sh", "/.claude/scripts/jj-session-start.sh"])
    | strip("PreToolUse";    ["/.claude/hooks/require-jj-new.sh", "/.claude/scripts/require-jj-new.sh"])
    | strip("WorktreeCreate";["/.claude/hooks/jj-workspace-create.sh", "/.claude/scripts/jj-workspace-create.sh"])
    | strip("WorktreeRemove";["/.claude/hooks/jj-workspace-remove.sh", "/.claude/scripts/jj-workspace-remove.sh"])
    | strip_value("PreCompact"; {hooks:[{type:"command", command:"jj status >/dev/null 2>&1 || true"}]})
    | (if ((.hooks // {}) | length) == 0 then del(.hooks) else . end);
  def add_allow: (.permissions //= {})
    | .permissions.allow = (((.permissions.allow // []) + [
        "Bash(jj status*)","Bash(jj diff*)","Bash(jj log*)","Bash(jj new*)",
        "Bash(jj commit*)","Bash(jj describe*)","Bash(jj bookmark*)","Bash(jj git push*)",
        "Bash(jj git fetch*)","Bash(jj rebase*)","Bash(jj squash*)","Bash(jj edit*)",
        "Bash(jj abandon*)","Bash(jj undo*)","Bash(jj op log*)","Bash(jj resolve*)",
        "Bash(jj root*)","Bash(jj file*)","Bash(jj split*)","Bash(jj config*)",
        "Bash(jj git remote*)","Bash(gh *)"
      ]) | unique);
  def add_deny: (.permissions //= {})
    | .permissions.deny = (((.permissions.deny // []) + ["Bash(git *)"]) | unique);
  def drop_deny:
    if (.permissions | type) == "object" and (.permissions.deny | type) == "array" then
      .permissions.deny = (.permissions.deny | map(select(. != "Bash(git *)")))
      | (if (.permissions.deny | length) == 0 then del(.permissions.deny) else . end)
      | (if (.permissions | length) == 0 then del(.permissions) else . end)
    else . end;
'


mkdir -p "$CLAUDE_DIR"

if [ "$MODE" = "tracked" ]; then
  # Tracked file owns hooks + the deny floor: the enforcement everyone in the
  # repo should get identically.
  merged_tracked=$(printf '%s' "$tracked_base" | jq \
    --arg ss "$SS" --arg rjn "$RJN" --arg wsc "$WSC" --arg wsr "$WSR" \
    "$JQ_DEFS"' (.hooks //= {}) | all_hooks | add_deny')
  printf '%s\n' "$merged_tracked" > "$SETTINGS_TRACKED"

  # Local file keeps only what is personal, and must SHED the hooks — hooks merge
  # additively across scopes, so leaving them here runs every handler twice. The
  # managed deny entry is dropped too, so a single file owns it; permissions merge
  # across scopes, so the tracked one still applies.
  merged_local=$(printf '%s' "$base" | jq \
    "$JQ_DEFS"' strip_all_hooks | drop_deny | add_allow')
  printf '%s\n' "$merged_local" > "$SETTINGS"
else
  # --local: the pre-#97 behaviour, everything in one untracked file.
  merged_local=$(printf '%s' "$base" | jq \
    --arg ss "$SS" --arg rjn "$RJN" --arg wsc "$WSC" --arg wsr "$WSR" \
    "$JQ_DEFS"' (.hooks //= {}) | all_hooks | add_allow | add_deny')
  printf '%s\n' "$merged_local" > "$SETTINGS"
fi

echo "mode=$MODE"
echo "settings=$settings_outcome"
echo "settings_tracked=$tracked_outcome"

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
