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

# --- smoke: the install must SOURCE what it wrote ---
# Everything above proves text landed in the right files. None of it proves the
# helpers exist, and the install ends by telling the user to restart — so a file
# that parses but defines nothing would be discovered by the user, not by us.

FAKE3="$(mktemp -d)"
OUT=$(HOME="$FAKE3" bash "$INSTALL" install)
printf '%s' "$OUT" | grep -q '^smoke=pass:' \
  && ok "smoke: real helper file sources and defines all four" || bad "smoke" "expected smoke=pass, got: $(printf '%s' "$OUT" | grep '^smoke=' || echo none)"

# Overwrite the INSTALLED copy with a file that parses and defines nothing, then
# re-run the smoke logic against it by re-installing from a plugin root whose
# source is that same empty file.
FAKE4="$(mktemp -d)"; STUBPLUG="$(mktemp -d)"
mkdir -p "$STUBPLUG/scripts" "$STUBPLUG/templates"
printf '# defines nothing at all\n' > "$STUBPLUG/scripts/jj-agent-helpers.sh"
cp "$SCRIPT_DIR/../templates/jj-agent-helpers-claudemd.md" "$STUBPLUG/templates/"
cp "$INSTALL" "$STUBPLUG/scripts/agent-helpers-install.sh"
OUT=$(HOME="$FAKE4" bash "$STUBPLUG/scripts/agent-helpers-install.sh" install)
printf '%s' "$OUT" | grep -q '^smoke=fail:.*jjctx' \
  && ok "smoke: a file defining nothing reports fail" || bad "smoke" "expected smoke=fail naming jjctx, got: $(printf '%s' "$OUT" | grep '^smoke=' || echo none)"

# A failing smoke is a report, not an abort — the files are already written.
[ -f "$FAKE4/.config/jj-agent-helpers/jj-agent-helpers.sh" ] \
  && ok "smoke: failure does not abort the install" || bad "smoke" "install aborted on smoke failure"

rm -rf "$FAKE3" "$FAKE4" "$STUBPLUG"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
