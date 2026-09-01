#!/usr/bin/env bash
set -euo pipefail

# Discovery-order contract: the specialist walk is documented in TWO places
# (receiving skill step 9, /peer-review command step 7). Both must name the
# installed-plugins tier, and the skill's line must order it between
# user-global and the peer-review-jj built-ins. Guards against the tiers
# drifting apart on a future edit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$SCRIPT_DIR/.."
SKILL="$PLUGIN_ROOT/skills/receiving-change-review/SKILL.md"
CMD="$PLUGIN_ROOT/commands/peer-review.md"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

line="$(grep -F '**Discovery order**' "$SKILL" || true)"
if [ -n "$line" ]; then
  ok "SKILL.md has a discovery-order line"
  if printf '%s' "$line" | awk '{
      ug = index($0, "user-global");
      pl = index($0, "installed plugins");
      bi = index($0, "peer-review-jj/agents");
      exit !(ug && pl && bi && ug < pl && pl < bi);
    }'; then
    ok "tier order: user-global < installed plugins < built-in"
  else
    bad "skill/order" "$line"
  fi
else
  bad "skill/line" "no '**Discovery order**' line in $SKILL"
fi

grep -F 'plugins/cache' "$SKILL" >/dev/null \
  && ok "SKILL.md documents the cache glob for plugin specialists" \
  || bad "skill/glob" "no plugins/cache resolution documented"

grep -F "installed plugins" "$CMD" >/dev/null \
  && ok "command doc names the installed-plugins tier" \
  || bad "cmd/tier" "peer-review.md discovery line not updated"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
