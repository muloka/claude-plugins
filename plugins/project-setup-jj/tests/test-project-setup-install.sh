#!/usr/bin/env bash
set -euo pipefail

# Installer contract for project-setup-install.sh (#78): copies, settings
# deep-merge (replace-by-identity at hook granularity), CLAUDE.md 4-case,
# malformed-JSON no-clobber. No jj needed — explicit plugin/project roots.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/../scripts/project-setup-install.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

# Fabricate a fake plugin root (scripts/ + templates/) once.
PLUG="$(mktemp -d)"
trap 'rm -rf "$PLUG"' EXIT
mkdir -p "$PLUG/scripts" "$PLUG/templates"
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  printf '#!/usr/bin/env bash\n# stub %s\n' "$s" > "$PLUG/scripts/$s"
done
cat > "$PLUG/templates/CLAUDE.md.template" <<'TPL'
<!-- jj-project-setup:start hash:PLACEHOLDER -->
## VCS — jj (Jujutsu)

Use jj, not git.
<!-- jj-project-setup:end -->
TPL
# Compute the real body hash and stamp it into the fabricated template's marker,
# exactly as a maintainer would, so case-2 "unchanged" is reachable.
md5hash() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum; fi | cut -c1-8; }
BODYHASH=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$PLUG/templates/CLAUDE.md.template" | sed '1d;$d' | md5hash)
sed "s/hash:PLACEHOLDER/hash:$BODYHASH/" "$PLUG/templates/CLAUDE.md.template" > "$PLUG/templates/CLAUDE.md.template.tmp"
mv "$PLUG/templates/CLAUDE.md.template.tmp" "$PLUG/templates/CLAUDE.md.template"

newproj() { mktemp -d; }   # fresh project root per case

# ---- Case 1: fresh install ----
P=$(newproj)
OUT=$(bash "$INSTALL" "$PLUG" "$P")
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  [ -x "$P/.claude/hooks/$s" ] && ok "fresh: $s copied +x" || bad "fresh" "$s not executable/copied"
done
jq empty "$P/.claude/settings.local.json" 2>/dev/null && ok "fresh: settings valid JSON" || bad "fresh" "settings not valid JSON"
for ev in SessionStart PreCompact PreToolUse WorktreeCreate WorktreeRemove; do
  [ "$(jq --arg e "$ev" '(.hooks[$e]|length) > 0' "$P/.claude/settings.local.json")" = true ] \
    && ok "fresh: hooks.$ev present" || bad "fresh" "hooks.$ev missing"
done
# Hook commands must be portable: $CLAUDE_PROJECT_DIR-relative, never an absolute
# machine path. An absolute path pins the settings file to one checkout — it cannot
# be shared with collaborators and resolves to nothing in a clone or jj workspace
# living elsewhere on disk.
allcmds=$(jq -r '[.hooks[][].hooks[].command] | .[]' "$P/.claude/settings.local.json")
n_abs=$(printf '%s\n' "$allcmds" | grep -c '^/' || true)
[ "$n_abs" -eq 0 ] && ok "fresh: no absolute hook paths" || bad "fresh" "$n_abs hook command(s) absolute: $allcmds"
n_portable=$(printf '%s\n' "$allcmds" | grep -c '^\$CLAUDE_PROJECT_DIR/\.claude/hooks/' || true)
[ "$n_portable" -eq 4 ] && ok "fresh: 4 hook paths use \$CLAUDE_PROJECT_DIR/.claude/hooks" || bad "fresh" "expected 4 portable hook paths under .claude/hooks, got $n_portable"
# Nothing may still point at the legacy .claude/scripts/ location.
n_legacy=$(printf '%s\n' "$allcmds" | grep -c '/\.claude/scripts/' || true)
[ "$n_legacy" -eq 0 ] && ok "fresh: no hook path points at legacy .claude/scripts/" || bad "fresh" "$n_legacy legacy hook path(s) remain"
[ "$(jq '.permissions.allow | index("Bash(gh *)") != null' "$P/.claude/settings.local.json")" = true ] && ok "fresh: allow has gh" || bad "fresh" "allow missing gh"
[ "$(jq '.permissions.deny | index("Bash(git *)") != null' "$P/.claude/settings.local.json")" = true ] && ok "fresh: deny has git" || bad "fresh" "deny missing git"
[ -f "$P/CLAUDE.md" ] && grep -q 'jj-project-setup:start' "$P/CLAUDE.md" && ok "fresh: CLAUDE.md created w/ marker" || bad "fresh" "CLAUDE.md missing marker"
printf '%s\n' "$OUT" | grep -qx 'settings=created' && ok "fresh: summary settings=created" || bad "fresh" "summary not created: $OUT"
printf '%s\n' "$OUT" | grep -qx 'claude_md=created' && ok "fresh: summary claude_md=created" || bad "fresh" "summary claude_md: $OUT"

# ---- Case 2: idempotent re-run (byte-identical) ----
BEFORE=$(cat "$P/.claude/settings.local.json")
OUT2=$(bash "$INSTALL" "$PLUG" "$P")
[ "$(cat "$P/.claude/settings.local.json")" = "$BEFORE" ] && ok "rerun: settings byte-identical" || bad "rerun" "settings changed on 2nd run"
printf '%s\n' "$OUT2" | grep -qx 'claude_md=unchanged' && ok "rerun: claude_md=unchanged" || bad "rerun" "claude_md not unchanged: $OUT2"

# ---- Case 3: unrelated hook + permission preserved ----
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"x","hooks":[{"type":"command","command":"/opt/mine/other.sh"}]}]},"permissions":{"allow":["Bash(mytool:*)"]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | index("/opt/mine/other.sh") != null' "$P/.claude/settings.local.json")" = true ] && ok "preserve: unrelated hook survives" || bad "preserve" "unrelated hook dropped"
[ "$(jq '.permissions.allow | index("Bash(mytool:*)") != null' "$P/.claude/settings.local.json")" = true ] && ok "preserve: unrelated permission survives" || bad "preserve" "unrelated permission dropped"
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "preserve: our SessionStart added exactly once" || bad "preserve" "our hook count != 1"

# ---- Case 4: stale-version managed hook replaced, not duplicated ----
# The seeded command uses the LEGACY .claude/scripts/ path, so this case doubles
# as the narrowest migration proof: identity must be recognised across the move.
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"OLD","hooks":[{"type":"command","command":"$P/.claude/scripts/jj-session-start.sh"}]}]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "stale: exactly one of our SessionStart" || bad "stale" "duplicate/zero after upgrade"
[ "$(jq '[.hooks.SessionStart[] | select(.matcher=="OLD")] | length' "$P/.claude/settings.local.json")" = 0 ] && ok "stale: OLD matcher gone" || bad "stale" "OLD entry survived"

# ---- Case 5: CLAUDE.md variants ----
# 5a matching hash -> unchanged, body untouched
P=$(newproj)
bash "$INSTALL" "$PLUG" "$P" >/dev/null           # creates CLAUDE.md w/ current hash
CM_BEFORE=$(cat "$P/CLAUDE.md")
OUT=$(bash "$INSTALL" "$PLUG" "$P")
[ "$(cat "$P/CLAUDE.md")" = "$CM_BEFORE" ] && printf '%s\n' "$OUT" | grep -qx 'claude_md=unchanged' && ok "claude_md 5a: matching hash unchanged" || bad "claude_md 5a" "changed or wrong summary"
# 5b no marker -> prepend, preserve existing
P=$(newproj); printf '# Existing\n\nkeep me\n' > "$P/CLAUDE.md"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
grep -q 'jj-project-setup:start' "$P/CLAUDE.md" && grep -q 'keep me' "$P/CLAUDE.md" && ok "claude_md 5b: prepended, existing kept" || bad "claude_md 5b" "marker or existing content missing"
# 5c differing hash -> section replaced, surrounding intact
P=$(newproj); mkdir -p "$P"
printf '# Top\n<!-- jj-project-setup:start hash:deadbeef -->\nOLD BODY\n<!-- jj-project-setup:end -->\n# Bottom\n' > "$P/CLAUDE.md"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
grep -q 'Use jj, not git.' "$P/CLAUDE.md" && ! grep -q 'OLD BODY' "$P/CLAUDE.md" && grep -q '# Top' "$P/CLAUDE.md" && grep -q '# Bottom' "$P/CLAUDE.md" && ok "claude_md 5c: section replaced, surroundings intact" || bad "claude_md 5c" "replace wrong"
# 5d marker on LINE 1 -> replaced without duplicating the marker pair.
# 5c always has content above the marker, so the prefix slice is 1,N with N>=1
# and the boundary never gets exercised. With the marker on line 1 the slice
# becomes `sed -n "1,0p"`, and BSD sed prints line 1 for an inverted range
# instead of nothing — leaving the stale start marker above the fresh one.
# A real project hit this: the file grew a duplicate start marker carrying the
# OLD hash, and because the installer reads the FIRST marker's hash it would
# recur on every subsequent run.
P=$(newproj); mkdir -p "$P"
printf '<!-- jj-project-setup:start hash:deadbeef -->\nOLD BODY\n<!-- jj-project-setup:end -->\n# Bottom\n' > "$P/CLAUDE.md"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
s_count=$(grep -c 'jj-project-setup:start' "$P/CLAUDE.md")
e_count=$(grep -c 'jj-project-setup:end' "$P/CLAUDE.md")
if [ "$s_count" -eq 1 ] && [ "$e_count" -eq 1 ] && ! grep -q 'deadbeef' "$P/CLAUDE.md" \
   && grep -q 'Use jj, not git.' "$P/CLAUDE.md" && ! grep -q 'OLD BODY' "$P/CLAUDE.md" \
   && grep -q '# Bottom' "$P/CLAUDE.md"; then
  ok "claude_md 5d: marker on line 1 replaced without duplication"
else
  bad "claude_md 5d" "start=$s_count end=$e_count (want 1/1, no stale deadbeef)"
fi
# 5e re-running over a line-1 marker stays at one pair (the defect compounded
# per run, so idempotence is the property that actually protects the file).
bash "$INSTALL" "$PLUG" "$P" >/dev/null
s_count2=$(grep -c 'jj-project-setup:start' "$P/CLAUDE.md")
if [ "$s_count2" -eq 1 ]; then
  ok "claude_md 5e: re-run over a line-1 marker stays at one pair"
else
  bad "claude_md 5e" "start markers after re-run: $s_count2 (want 1)"
fi
# 5f prose ABOVE the block that merely names the marker must not be mistaken
# for it. The installer located markers by substring, so a sentence like
# "never edit inside the jj-project-setup:start block" sitting above the real
# marker became s_line, and everything from it down to the real end marker was
# replaced — silently destroying the prose and any content between. A real
# project (sususisu) documents the convention in exactly this way, just below
# its block rather than above, so the reordering that triggers this is one edit
# away.
P=$(newproj); mkdir -p "$P"
printf 'Docs: never edit inside the jj-project-setup:start block.\n# Top\n<!-- jj-project-setup:start hash:deadbeef -->\nOLD BODY\n<!-- jj-project-setup:end -->\n# Bottom\n' > "$P/CLAUDE.md"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
if grep -q 'Docs: never edit inside' "$P/CLAUDE.md" && grep -q '# Top' "$P/CLAUDE.md" \
   && grep -q '# Bottom' "$P/CLAUDE.md" && grep -q 'Use jj, not git.' "$P/CLAUDE.md" \
   && ! grep -q 'OLD BODY' "$P/CLAUDE.md"; then
  ok "claude_md 5f: prose above the block is not mistaken for the marker"
else
  bad "claude_md 5f" "prose/heading above the block was destroyed: $(head -3 "$P/CLAUDE.md" | tr '\n' '|')"
fi
# 5g prose BELOW the block (the shape a real project actually has) keeps
# working. Regression guard — expected to pass before and after the fix.
P=$(newproj); mkdir -p "$P"
printf '<!-- jj-project-setup:start hash:deadbeef -->\nOLD BODY\n<!-- jj-project-setup:end -->\n# Notes\nThis file has a jj-project-setup:start/end managed block.\n' > "$P/CLAUDE.md"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
if grep -q 'managed block' "$P/CLAUDE.md" && grep -q 'Use jj, not git.' "$P/CLAUDE.md" \
   && ! grep -q 'OLD BODY' "$P/CLAUDE.md" \
   && [ "$(grep -cE '^[[:space:]]*<!--[[:space:]]*jj-project-setup:start' "$P/CLAUDE.md")" -eq 1 ]; then
  ok "claude_md 5g: prose below the block still updates cleanly"
else
  bad "claude_md 5g" "below-block prose case broke"
fi

# ---- Case 6: malformed existing settings -> abort, no clobber ----
P=$(newproj); mkdir -p "$P/.claude"
printf '{not json' > "$P/.claude/settings.local.json"
RAW_BEFORE=$(cat "$P/.claude/settings.local.json")
if bash "$INSTALL" "$PLUG" "$P" >/dev/null 2>&1; then bad "malformed" "exited 0 on invalid JSON"; else ok "malformed: non-zero exit"; fi
[ "$(cat "$P/.claude/settings.local.json")" = "$RAW_BEFORE" ] && ok "malformed: file untouched" || bad "malformed" "file was clobbered"
[ ! -d "$P/.claude/hooks" ] && ok "malformed: no side effects (hooks/ not created)" || bad "malformed" ".claude/hooks created before abort"

# ---- Case 7: user hook co-located in same entry survives (hook granularity) ----
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"/opt/mine/user.sh"},{"type":"command","command":"$P/.claude/scripts/jj-session-start.sh"}]}]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | index("/opt/mine/user.sh") != null' "$P/.claude/settings.local.json")" = true ] && ok "colocated: user hook survives" || bad "colocated" "user hook dropped (entry-granularity bug)"
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "colocated: our hook present once" || bad "colocated" "our hook count != 1"

# ---- Case 8: a project on the OLD .claude/scripts/ layout migrates ----
# Project hook handlers belong in .claude/hooks/ — the directory every example in
# the hooks docs uses. The migration's whole risk is DUPLICATION: upsert strips a
# managed hook by matching its command suffix, so if it only knew the new
# .claude/hooks/ suffix the pre-existing .claude/scripts/ registration would
# survive untouched and the fresh one would be appended beside it. The project
# would then carry TWO registrations per event and BOTH would fire — the session
# banner printed twice, require-jj-new evaluated twice, the workspace hooks
# creating and removing a workspace twice. Hence every count assertion below
# matches on BASENAME, not on the new path: matching the new path alone would
# score a duplicate as a pass, which is the exact defect being guarded.
oldlayout() {   # oldlayout <project> — seed a project as the previous installer left it
  local p="$1"
  mkdir -p "$p/.claude/scripts"
  for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
    printf '#!/usr/bin/env bash\n# OLD %s\n' "$s" > "$p/.claude/scripts/$s"
    chmod +x "$p/.claude/scripts/$s"
  done
  cat > "$p/.claude/settings.local.json" <<JSON
{"hooks":{
  "SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"\$CLAUDE_PROJECT_DIR/.claude/scripts/jj-session-start.sh","async":false}]}],
  "PreToolUse":[{"matcher":"Edit|Write|NotebookEdit","hooks":[{"type":"command","command":"\$CLAUDE_PROJECT_DIR/.claude/scripts/require-jj-new.sh"}]}],
  "WorktreeCreate":[{"hooks":[{"type":"command","command":"\$CLAUDE_PROJECT_DIR/.claude/scripts/jj-workspace-create.sh"}]}],
  "WorktreeRemove":[{"hooks":[{"type":"command","command":"\$CLAUDE_PROJECT_DIR/.claude/scripts/jj-workspace-remove.sh"}]}]
}}
JSON
}

P=$(newproj); oldlayout "$P"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
# 8a scripts land in the new home
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  [ -x "$P/.claude/hooks/$s" ] && ok "migrate: $s now in .claude/hooks/ +x" || bad "migrate" "$s not in .claude/hooks/"
done
# 8b settings point at the new home, and nothing points at the old one
mig_cmds=$(jq -r '[.hooks[][].hooks[].command] | .[]' "$P/.claude/settings.local.json")
m_new=$(printf '%s\n' "$mig_cmds" | grep -c '^\$CLAUDE_PROJECT_DIR/\.claude/hooks/' || true)
[ "$m_new" -eq 4 ] && ok "migrate: 4 hook commands point at .claude/hooks/" || bad "migrate" "expected 4 new-path commands, got $m_new"
m_old=$(printf '%s\n' "$mig_cmds" | grep -c '/\.claude/scripts/' || true)
[ "$m_old" -eq 0 ] && ok "migrate: zero commands still point at .claude/scripts/" || bad "migrate" "$m_old stale command(s) still registered"
# 8c exactly ONE registration per hook — the duplicate-registration guard
for pair in "SessionStart:jj-session-start.sh" "PreToolUse:require-jj-new.sh" \
            "WorktreeCreate:jj-workspace-create.sh" "WorktreeRemove:jj-workspace-remove.sh"; do
  ev="${pair%%:*}"; base="${pair##*:}"
  n=$(jq --arg e "$ev" --arg b "$base" '[.hooks[$e][].hooks[].command] | map(select(endswith($b))) | length' "$P/.claude/settings.local.json")
  [ "$n" = 1 ] && ok "migrate: exactly one $ev registration for $base" || bad "migrate" "$ev has $n registrations of $base (want 1 — both would fire)"
done
# 8d the four old files are gone
leftover=0
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  [ -e "$P/.claude/scripts/$s" ] && leftover=$((leftover+1))
done
[ "$leftover" -eq 0 ] && ok "migrate: all four legacy scripts removed from .claude/scripts/" || bad "migrate" "$leftover legacy script(s) left behind"
# 8e the legacy directory itself is gone once nothing else remains
[ ! -d "$P/.claude/scripts" ] && ok "migrate: empty .claude/scripts/ removed" || bad "migrate" ".claude/scripts/ survived while empty"

# ---- Case 9: a statusline installed by a DIFFERENT command must survive ----
# .claude/scripts/ is not ours alone: /statusline-jj-setup puts statusline-jj.sh
# there. A blanket `rm -rf .claude/scripts` during migration would silently break
# that user's statusline — a command they never ran deleting a file it does not
# own. The directory may only go when it is empty of everything else.
P=$(newproj); oldlayout "$P"
printf '#!/usr/bin/env bash\necho statusline\n' > "$P/.claude/scripts/statusline-jj.sh"
chmod +x "$P/.claude/scripts/statusline-jj.sh"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ -f "$P/.claude/scripts/statusline-jj.sh" ] && ok "coexist: statusline-jj.sh survives migration" || bad "coexist" "statusline-jj.sh was DELETED by /project-setup"
[ -x "$P/.claude/scripts/statusline-jj.sh" ] && ok "coexist: statusline-jj.sh still executable" || bad "coexist" "statusline lost +x"
[ -d "$P/.claude/scripts" ] && ok "coexist: .claude/scripts/ kept (not empty)" || bad "coexist" ".claude/scripts/ removed while statusline lived there"
s_left=0
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  [ -e "$P/.claude/scripts/$s" ] && s_left=$((s_left+1))
done
[ "$s_left" -eq 0 ] && ok "coexist: our four legacy scripts still removed" || bad "coexist" "$s_left legacy script(s) left behind"
[ -x "$P/.claude/hooks/jj-session-start.sh" ] && ok "coexist: hooks still installed to .claude/hooks/" || bad "coexist" "hooks not installed"

# ---- Case 10: re-running after migration is idempotent ----
P=$(newproj); oldlayout "$P"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
MIG_BEFORE=$(cat "$P/.claude/settings.local.json")
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(cat "$P/.claude/settings.local.json")" = "$MIG_BEFORE" ] && ok "migrate-rerun: settings byte-identical" || bad "migrate-rerun" "settings churned on re-run after migration"
for pair in "SessionStart:jj-session-start.sh" "PreToolUse:require-jj-new.sh" \
            "WorktreeCreate:jj-workspace-create.sh" "WorktreeRemove:jj-workspace-remove.sh"; do
  ev="${pair%%:*}"; base="${pair##*:}"
  n=$(jq --arg e "$ev" --arg b "$base" '[.hooks[$e][].hooks[].command] | map(select(endswith($b))) | length' "$P/.claude/settings.local.json")
  [ "$n" = 1 ] && ok "migrate-rerun: $ev still has exactly one $base" || bad "migrate-rerun" "$ev grew to $n registrations of $base"
done
[ ! -d "$P/.claude/scripts" ] && ok "migrate-rerun: legacy dir stays gone" || bad "migrate-rerun" ".claude/scripts/ reappeared"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
