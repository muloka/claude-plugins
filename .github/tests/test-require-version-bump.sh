#!/usr/bin/env bash
set -euo pipefail

# Proves require-version-bump.sh: RED when a plugin's files change without a
# version bump, GREEN otherwise. No VCS — each case builds a head/ tree and a
# base/ tree as plain directories (BASE_DIR), exactly what the workflow's second
# checkout provides. This runs even under the jj rail (no `git` anywhere).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/require-version-bump.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# new_case -> prints a fresh dir holding empty head/ and base/ subtrees
new_case() {
  local d; d="$(mktemp -d "$TMPROOT/c.XXXXXX")"
  mkdir -p "$d/head" "$d/base"
  printf '%s' "$d"
}

# manifest <tree> <plugin> <version>
manifest() {
  mkdir -p "$1/plugins/$2/.claude-plugin"
  printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$2" "$3" \
    > "$1/plugins/$2/.claude-plugin/plugin.json"
}

# file <path> <contents>
file() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

# run <case_dir> <changed_files> -> echoes the script's exit code
run() {
  local rc=0
  ( cd "$1/head" && CHANGED_FILES="$2" BASE_DIR="$1/base" bash "$SCRIPT" ) >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --- case 1: plugin file changed, version NOT bumped -> RED (the core proof) ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0; file "$C/base/plugins/foo/skills/x/SKILL.md" v1
manifest "$C/head" foo 0.1.0; file "$C/head/plugins/foo/skills/x/SKILL.md" v2
rc="$(run "$C" 'plugins/foo/skills/x/SKILL.md')"
[ "$rc" = 1 ] && ok "case1: changed without bump -> red" || bad "case1" "rc=$rc want 1"

# --- case 2: plugin file changed AND version bumped -> GREEN ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0; file "$C/base/plugins/foo/skills/x/SKILL.md" v1
manifest "$C/head" foo 0.1.1; file "$C/head/plugins/foo/skills/x/SKILL.md" v2
rc="$(run "$C" "$(printf 'plugins/foo/skills/x/SKILL.md\nplugins/foo/.claude-plugin/plugin.json')")"
[ "$rc" = 0 ] && ok "case2: changed with bump -> green" || bad "case2" "rc=$rc want 0"

# --- case 3: no plugin files changed -> GREEN (script no-ops) ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0
manifest "$C/head" foo 0.1.0
rc="$(run "$C" '.github/workflows/foo.yml')"
[ "$rc" = 0 ] && ok "case3: no plugin change -> green" || bad "case3" "rc=$rc want 0"

# --- case 4: brand-new plugin (absent in base) -> GREEN ---
C="$(new_case)"
manifest "$C/head" newp 0.1.0; file "$C/head/plugins/newp/skills/x/SKILL.md" v1
rc="$(run "$C" "$(printf 'plugins/newp/.claude-plugin/plugin.json\nplugins/newp/skills/x/SKILL.md')")"
[ "$rc" = 0 ] && ok "case4: new plugin -> green" || bad "case4" "rc=$rc want 0"

# --- case 5: full plugin deletion (absent in head) -> GREEN ---
C="$(new_case)"
manifest "$C/base" gone 0.1.0; file "$C/base/plugins/gone/skills/x/SKILL.md" v1
rc="$(run "$C" "$(printf 'plugins/gone/.claude-plugin/plugin.json\nplugins/gone/skills/x/SKILL.md')")"
[ "$rc" = 0 ] && ok "case5: full deletion -> green" || bad "case5" "rc=$rc want 0"

# --- case 6: two plugins, one bumped one not -> RED, names only the unbumped ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0; file "$C/base/plugins/foo/skills/x/SKILL.md" v1
manifest "$C/base" bar 0.1.0; file "$C/base/plugins/bar/skills/y/SKILL.md" v1
manifest "$C/head" foo 0.1.1; file "$C/head/plugins/foo/skills/x/SKILL.md" v2
manifest "$C/head" bar 0.1.0; file "$C/head/plugins/bar/skills/y/SKILL.md" v2
CF="$(printf 'plugins/foo/skills/x/SKILL.md\nplugins/foo/.claude-plugin/plugin.json\nplugins/bar/skills/y/SKILL.md')"
out="$( cd "$C/head" && CHANGED_FILES="$CF" BASE_DIR="$C/base" bash "$SCRIPT" 2>&1 )" && rc=0 || rc=$?
[ "$rc" = 1 ] && ok "case6: mixed -> red" || bad "case6" "rc=$rc want 1"
printf '%s' "$out" | grep -q "bar" && ok "case6: names unbumped 'bar'" || bad "case6-name" "no bar in: $out"
printf '%s' "$out" | grep -q "'foo'" && bad "case6-name" "bumped foo wrongly flagged" || ok "case6: bumped 'foo' not flagged"

echo ""
echo "$pass passed, $fail failed"
test "$fail" -eq 0
