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
  [ -x "$P/.claude/scripts/$s" ] && ok "fresh: $s copied +x" || bad "fresh" "$s not executable/copied"
done
jq empty "$P/.claude/settings.local.json" 2>/dev/null && ok "fresh: settings valid JSON" || bad "fresh" "settings not valid JSON"
for ev in SessionStart PreCompact PreToolUse WorktreeCreate WorktreeRemove; do
  [ "$(jq --arg e "$ev" '(.hooks[$e]|length) > 0' "$P/.claude/settings.local.json")" = true ] \
    && ok "fresh: hooks.$ev present" || bad "fresh" "hooks.$ev missing"
done
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
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("/.claude/scripts/jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "preserve: our SessionStart added exactly once" || bad "preserve" "our hook count != 1"

# ---- Case 4: stale-version managed hook replaced, not duplicated ----
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"OLD","hooks":[{"type":"command","command":"$P/.claude/scripts/jj-session-start.sh"}]}]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("/.claude/scripts/jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "stale: exactly one of our SessionStart" || bad "stale" "duplicate/zero after upgrade"
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

# ---- Case 6: malformed existing settings -> abort, no clobber ----
P=$(newproj); mkdir -p "$P/.claude"
printf '{not json' > "$P/.claude/settings.local.json"
RAW_BEFORE=$(cat "$P/.claude/settings.local.json")
if bash "$INSTALL" "$PLUG" "$P" >/dev/null 2>&1; then bad "malformed" "exited 0 on invalid JSON"; else ok "malformed: non-zero exit"; fi
[ "$(cat "$P/.claude/settings.local.json")" = "$RAW_BEFORE" ] && ok "malformed: file untouched" || bad "malformed" "file was clobbered"
[ ! -d "$P/.claude/scripts" ] && ok "malformed: no side effects (scripts/ not created)" || bad "malformed" ".claude/scripts created before abort"

# ---- Case 7: user hook co-located in same entry survives (hook granularity) ----
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"/opt/mine/user.sh"},{"type":"command","command":"$P/.claude/scripts/jj-session-start.sh"}]}]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | index("/opt/mine/user.sh") != null' "$P/.claude/settings.local.json")" = true ] && ok "colocated: user hook survives" || bad "colocated" "user hook dropped (entry-granularity bug)"
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("/.claude/scripts/jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "colocated: our hook present once" || bad "colocated" "our hook count != 1"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
