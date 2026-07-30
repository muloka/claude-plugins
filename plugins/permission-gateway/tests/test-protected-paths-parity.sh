#!/usr/bin/env bash
set -euo pipefail

# The protected-path set exists TWICE: once in gate-config-writes.sh (which sees
# Write/Edit) and once in permission-gate.sh (which sees Bash). They were
# duplicated on purpose — a shared file would itself be a bypass target, and one
# more thing needing a gate — but duplication buys that safety with a drift risk,
# and drift here is silent. Widening one copy while leaving the other narrower
# reopens #123 on whichever tool the stale copy handles, and every existing test
# stays green because each suite exercises only its own script.
#
# This lint is the thing that fails instead. It compares the two regexes
# literally; it does not re-derive either from the other, because a corpus taken
# from the artifact under test cannot detect that artifact's drift.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../scripts/permission-gate.sh"
CONFIG_GATE="$SCRIPT_DIR/../scripts/gate-config-writes.sh"

pass=0
fail=0

# Pull the first single-quoted group that starts with the permission-gate token
# out of each file. Anchored on the token rather than on a line number or a
# variable name so that moving or renaming either copy does not quietly stop the
# lint from finding it.
extract_re() {
  grep -oE "'\(permission-gate[^']*\)'" "$1" | head -1 | sed "s/^'//;s/'$//"
}

gate_re=$(extract_re "$GATE" || true)
config_re=$(extract_re "$CONFIG_GATE" || true)

# An empty extraction means the lint lost track of its own target — that must
# fail loudly rather than compare "" with "" and report parity.
if [ -z "$gate_re" ]; then
  echo "  FAIL: no protected-path regex found in permission-gate.sh — lint cannot see its target"
  fail=$((fail + 1))
else
  echo "  PASS: found protected-path regex in permission-gate.sh"
  pass=$((pass + 1))
fi

if [ -z "$config_re" ]; then
  echo "  FAIL: no protected-path regex found in gate-config-writes.sh — lint cannot see its target"
  fail=$((fail + 1))
else
  echo "  PASS: found protected-path regex in gate-config-writes.sh"
  pass=$((pass + 1))
fi

if [ -n "$gate_re" ] && [ -n "$config_re" ]; then
  if [ "$gate_re" = "$config_re" ]; then
    echo "  PASS: the two protected-path regexes are identical"
    pass=$((pass + 1))
  else
    echo "  FAIL: protected-path regexes have drifted"
    echo "        permission-gate.sh     : $gate_re"
    echo "        gate-config-writes.sh  : $config_re"
    fail=$((fail + 1))
  fi
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
