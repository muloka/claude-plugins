#!/usr/bin/env bash
set -euo pipefail

# The protected-path set exists TWICE: once in gate-config-writes.sh (which sees
# Write/Edit) and once in permission-gate.sh (which sees Bash). They are
# duplicated on purpose — a shared sourced file would itself be a bypass target,
# and one more thing needing a gate — but that buys safety with a drift risk, and
# drift here is silent.
#
# THIS LINT USED TO COMPARE THE TWO REGEXES AS STRINGS, AND THAT WAS NOT ENOUGH.
# It stayed green while `.claude//settings.json` was gated on the Bash side and
# ungated through the Write tool, because the two regexes were genuinely
# identical — only one side normalized its input before matching. Textual parity
# is not behavioural parity. The behavioural half below is the load-bearing one;
# the textual half is kept because it localizes a different failure (someone
# editing one copy) to the line that caused it.
#
# The corpus is written from the CONCEPT — "files that decide which commands are
# approved, which are blocked, and which hooks run" — plus the spellings a shell
# accepts for the same file. It is deliberately NOT derived from either matcher,
# because a corpus taken from the artifact under test cannot detect that
# artifact's drift.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../scripts/permission-gate.sh"
CONFIG_GATE="$SCRIPT_DIR/../scripts/gate-config-writes.sh"

pass=0
fail=0

# --- Behavioural parity ------------------------------------------------------
# Same file, both tools. A write to a protected path must require confirmation
# whichever tool the caller reaches for; a gate is worth nothing if the other
# door is open.

# Pass-through is EMPTY STDOUT, not a JSON document saying "allow" — so the
# empty case has to be handled in shell. Piping nothing into `jq '... // "none"'`
# yields nothing at all: jq never runs its filter on a document that isn't there,
# and the default never fires.
write_decision() {
  local out
  out=$(jq -nc --arg p "$1" '{tool_input:{file_path:$p}, tool_name:"Write", hook_event_name:"PreToolUse"}' \
    | bash "$CONFIG_GATE" 2>/dev/null) || true
  [ -n "$out" ] || { echo none; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}

bash_decision() {
  local out
  out=$(jq -nc --arg c "echo x > $1" '{tool_input:{command:$c}, tool_name:"Bash", hook_event_name:"PreToolUse"}' \
    | bash "$GATE" 2>/dev/null) || true
  [ -n "$out" ] || { echo none; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "malformed"' 2>/dev/null || echo malformed
}

echo "=== Behavioural parity: a protected path must be gated via BOTH tools ==="
while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in \#*) continue ;; esac
  w=$(write_decision "$p")
  b=$(bash_decision "$p")
  if [ "$w" = "ask" ] && [ "$b" = "ask" ]; then
    pass=$((pass + 1))
    echo "  PASS: $p"
  else
    fail=$((fail + 1))
    echo "  FAIL: $p — Write gate said '$w', Bash gate said '$b' (both must be 'ask')"
  fi
done <<'PATHS'
.claude/settings.json
.claude/settings.local.json
.claude/hooks/require-jj-new.sh
.claude/hooks/jj-session-start.sh
.claude/scripts/statusline-jj.sh
.claude-plugin/plugin.json
.claude/permission-gateway.local.md
plugins/permission-gateway/scripts/permission-gate.sh
./.claude/settings.json
/Users/me/project/.claude/settings.json
.claude//settings.json
.claude/./settings.json
.claude/././settings.json
.claude//hooks//require-jj-new.sh
.claude/./hooks/require-jj-new.sh
/Users/me/project/.claude//hooks/require-jj-new.sh
PATHS

# Ordinary files must stay ungated on the Write side. The Bash side is NOT
# asserted here: it matches a deliberately broader fragment set (a bare
# `settings.json` counts) because it cannot see which argument is a path, so it
# over-asks by design. Over-asking is a prompt; under-asking is a bypass, and
# only one of those is worth a lint.
echo "=== Ordinary files stay ungated on the Write side ==="
while IFS= read -r p; do
  [ -n "$p" ] || continue
  w=$(write_decision "$p")
  if [ "$w" = "none" ]; then
    pass=$((pass + 1))
    echo "  PASS: $p"
  else
    fail=$((fail + 1))
    echo "  FAIL: $p — expected pass-through on the Write gate, got '$w'"
  fi
done <<'PATHS'
src/app.js
README.md
package.json
src//app.js
src/./app.js
docs/settings.md
.github/workflows/test.yml
PATHS

# --- Textual parity ----------------------------------------------------------
# Kept as a second, cheaper signal. It cannot detect a normalization difference —
# that is what the behavioural half above is for — but it names the exact line
# when someone widens one copy of the regex and not the other.
echo "=== Textual parity: the two regexes are still identical ==="
extract_re() {
  grep -oE "'\(permission-gate[^']*\)'" "$1" | head -1 | sed "s/^'//;s/'$//"
}
gate_re=$(extract_re "$GATE" || true)
config_re=$(extract_re "$CONFIG_GATE" || true)

if [ -z "$gate_re" ] || [ -z "$config_re" ]; then
  echo "  FAIL: could not find the protected-path regex in one or both scripts — the lint lost its target"
  fail=$((fail + 1))
elif [ "$gate_re" = "$config_re" ]; then
  echo "  PASS: identical in both scripts"
  pass=$((pass + 1))
else
  echo "  FAIL: protected-path regexes have drifted"
  echo "        permission-gate.sh    : $gate_re"
  echo "        gate-config-writes.sh : $config_re"
  fail=$((fail + 1))
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
