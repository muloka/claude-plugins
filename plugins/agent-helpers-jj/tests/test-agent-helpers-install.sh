#!/usr/bin/env bash
set -euo pipefail

# Installer idempotency + reversibility against a FAKE $HOME.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/../scripts/agent-helpers-install.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

FAKE="$(mktemp -d)"
FAKE2="$(mktemp -d)"
trap 'rm -rf "$FAKE" "$FAKE2"' EXIT

# seed a realistic home
mkdir -p "$FAKE/.claude"
printf '# my zshrc\nexport FOO=1\n' > "$FAKE/.zshrc"
printf '# My global instructions\n\nPrefer jj over git.\n' > "$FAKE/.claude/CLAUDE.md"
printf '{\n  "permissions": {\n    "allow": ["Bash(ls:*)"]\n  }\n}\n' > "$FAKE/.claude/settings.json"

ZSHRC_ORIG="$(cat "$FAKE/.zshrc")"
CLAUDE_ORIG="$(cat "$FAKE/.claude/CLAUDE.md")"
SETTINGS_ORIG_SEMANTIC="$(jq -S . "$FAKE/.claude/settings.json")"

run() { HOME="$FAKE" bash "$INSTALL" "$1"; }

# --- install ---
run install
grep -qxF '# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>' "$FAKE/.zshrc" && ok "zshrc fence present" || bad "install/zshrc" "no fence"
grep -qF 'source' "$FAKE/.zshrc" && grep -qF '.config/jj-agent-helpers/jj-agent-helpers.sh' "$FAKE/.zshrc" && ok "zshrc source line present" || bad "install/zshrc" "no source line"
[ -f "$FAKE/.config/jj-agent-helpers/jj-agent-helpers.sh" ] && ok "helper script copied" || bad "install/copy" "missing"
grep -qxF '<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->' "$FAKE/.claude/CLAUDE.md" && ok "CLAUDE.md fence present" || bad "install/claude" "no fence"
[ "$(jq -r '.permissions.allow | index("Bash(jjctx:*)") != null' "$FAKE/.claude/settings.json")" = true ] && ok "settings allowlist added" || bad "install/settings" "jjctx missing"
[ "$(jq -r '.permissions.allow | index("Bash(ls:*)") != null' "$FAKE/.claude/settings.json")" = true ] && ok "settings preserved existing entry" || bad "install/settings" "clobbered ls"

# --- idempotent second install ---
run install
zcount=$(grep -cxF '# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>' "$FAKE/.zshrc")
[ "$zcount" -eq 1 ] && ok "idempotent: one zshrc fence" || bad "idempotent/zshrc" "count=$zcount"
ccount=$(grep -cxF '<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->' "$FAKE/.claude/CLAUDE.md")
[ "$ccount" -eq 1 ] && ok "idempotent: one CLAUDE.md fence" || bad "idempotent/claude" "count=$ccount"
jcount=$(jq '[.permissions.allow[] | select(. == "Bash(jjctx:*)")] | length' "$FAKE/.claude/settings.json")
[ "$jcount" -eq 1 ] && ok "idempotent: no duplicate allowlist value" || bad "idempotent/settings" "count=$jcount"

# --- remove restores originals ---
run remove
[ "$(cat "$FAKE/.zshrc")" = "$ZSHRC_ORIG" ] && ok "remove restores ~/.zshrc byte-identical" || bad "remove/zshrc" "differs: $(cat "$FAKE/.zshrc")"
[ "$(cat "$FAKE/.claude/CLAUDE.md")" = "$CLAUDE_ORIG" ] && ok "remove restores CLAUDE.md byte-identical" || bad "remove/claude" "differs"
[ "$(jq -S . "$FAKE/.claude/settings.json")" = "$SETTINGS_ORIG_SEMANTIC" ] && ok "remove restores settings.json semantically" || bad "remove/settings" "differs: $(jq -S . "$FAKE/.claude/settings.json")"
[ ! -f "$FAKE/.config/jj-agent-helpers/jj-agent-helpers.sh" ] && ok "remove deletes helper script" || bad "remove/copy" "still present"

# --- missing-file paths ---
HOME="$FAKE2" bash "$INSTALL" install
grep -qxF '# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>' "$FAKE2/.zshrc" && ok "install creates missing ~/.zshrc" || bad "missing/zshrc" "not created"
[ "$(jq -r '.permissions.allow | index("Bash(jjctx:*)") != null' "$FAKE2/.claude/settings.json")" = true ] && ok "install creates missing settings.json with allow" || bad "missing/settings" "not created"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
