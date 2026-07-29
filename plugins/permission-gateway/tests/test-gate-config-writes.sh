#!/usr/bin/env bash
# gate-config-writes.sh — "gate the gate".
#
# This script had NO test coverage. The plugin's other suite
# (test-permission-gate.sh, 142 assertions) exercises permission-gate.sh only;
# it contains zero references to this one. The guard that makes it safe to put
# permission rules in a file an agent can edit was itself unasserted.
#
# That was tolerable while everything lived in an untracked
# settings.local.json, where weakening a rule cost one machine. It stops being
# tolerable under #97, which tracks .claude/settings.json and .claude/hooks/:
# weakening a rule then propagates to everyone through a pull request. Written
# as the blocking prerequisite for that change.
#
# Two classes below, labelled, because they are not equally strong:
#   - REGRESSION GUARDS for behaviour that already worked. Green on first run,
#     so they prove nothing by themselves; each was verified by mutating the
#     pattern and watching it go red.
#   - FAIL-FIRST for the hook-script gap, which was genuinely open: every
#     .claude/hooks/ assertion below failed before the pattern was widened.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../scripts/gate-config-writes.sh"
MANIFEST="$SCRIPT_DIR/../.claude-plugin/plugin.json"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# jq --arg, never string interpolation. A path containing a double quote or a
# backslash cannot be interpolated into JSON: the payload is malformed, the
# gate's own `jq -r` yields "", and a "passes through" assertion then succeeds
# because there was nothing to inspect — indistinguishable from real success.
run_gate() {
  jq -nc --arg p "$1" --arg t "${2:-Write}" \
    '{tool_input:{file_path:$p}, tool_name:$t, hook_event_name:"PreToolUse"}' \
    | bash "$GATE" 2>/dev/null || true
}

decision_of() {
  run_gate "$1" "${2:-Write}" | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null
}

assert_ask() {
  local name="$1" path="$2" tool="${3:-Write}"
  if [ "$(decision_of "$path" "$tool")" = "ask" ]; then
    ok "$name"
  else
    bad "$name — expected ask for '$path' via $tool, got: $(run_gate "$path" "$tool")"
  fi
}

assert_passthrough() {
  local name="$1" path="$2" tool="${3:-Write}"
  local out
  out=$(run_gate "$path" "$tool")
  if [ -z "$out" ]; then
    ok "$name"
  else
    bad "$name — expected pass-through for '$path', got: $out"
  fi
}

echo "=== REGRESSION GUARDS: hook registration files are gated ==="
# Removing or rewriting a hook registration disables every gate at once, which
# is why these are protected. Relative and absolute forms both, since the tool
# reports whichever the caller used.
assert_ask "tracked project settings"        ".claude/settings.json"
assert_ask "local settings"                  ".claude/settings.local.json"
assert_ask "settings, absolute path"         "/Users/me/proj/.claude/settings.json"
assert_ask "settings, nested project"        "/tmp/a/b/.claude/settings.local.json"
assert_ask "plugin manifest dir"             ".claude-plugin/plugin.json"
assert_ask "gateway local rules"             ".claude/permission-gateway.local.md"
# The evaluation engine itself, and this guard, whose path contains
# "permission-gateway" and therefore matches "permission-gate".
assert_ask "the evaluation engine"           "plugins/permission-gateway/scripts/permission-gate.sh"
assert_ask "this guard itself"               "plugins/permission-gateway/scripts/gate-config-writes.sh"
# Matching is case-insensitive (grep -qi); a case-shifted path must not slip by.
assert_ask "case-insensitive match"          "/Users/me/.CLAUDE/Settings.json"

echo "=== REGRESSION GUARDS: both write-capable tools are gated ==="
# The manifest registers this script on Write AND Edit. A guard wired to only
# one is bypassed by using the other, and nothing else asserts the pairing.
assert_ask "settings via Write"              ".claude/settings.json" "Write"
assert_ask "settings via Edit"               ".claude/settings.json" "Edit"

echo "=== FAIL-FIRST: the hook SCRIPTS are gated, not just their registration ==="
# The header comment justifies gating settings because "removing hooks disables
# the gate". Editing the hook script does the same thing more directly, and was
# NOT gated: every assertion in this block passed through before the pattern was
# widened to include .claude/hooks/ and the legacy .claude/scripts/.
#
# #97 is what makes this load-bearing. It tracks .claude/hooks/, so a neutered
# block-raw-git.sh would travel to every collaborator via a merged PR rather
# than dying with one working copy.
assert_ask "hook script: raw-git wall"       ".claude/hooks/block-raw-git.sh"
assert_ask "hook script: require-jj-new"     ".claude/hooks/require-jj-new.sh"
assert_ask "hook script, absolute path"      "/Users/me/proj/.claude/hooks/block-raw-git.sh"
assert_ask "hook script via Edit"            ".claude/hooks/block-raw-git.sh" "Edit"
# LEGACY_DST in project-setup-install.sh. Old installs still register hooks from
# here, so it is a live bypass until those projects are migrated.
assert_ask "legacy hook location"            ".claude/scripts/block-raw-git.sh"

echo "=== REGRESSION GUARDS: unrelated writes pass through ==="
# A gate that asks about everything trains the user to approve reflexively,
# which is the same outcome as no gate. These pin that it stays narrow.
assert_passthrough "ordinary source file"    "src/main.js"
assert_passthrough "documentation"           "README.md"
assert_passthrough "prose naming settings"   "docs/settings-guide.md"
assert_passthrough "a .claude sibling dir"   ".claudeignore"
assert_passthrough "project file, abs path"  "/Users/me/proj/src/lib.ts"

# Deliberately NOT a pass-through case, though it looks like one: any path
# containing "permission-gate" is protected, so the plugin's own tests, README
# and docs all ask. Broad, and asserted here so the breadth is a recorded
# decision rather than a surprise — it errs toward asking about files that
# describe the gate, which is the safe direction for a fail-closed guard.
assert_ask "the plugin's own test file"      "plugins/permission-gateway/tests/test-gate-config-writes.sh"
assert_ask "the plugin's own README"         "plugins/permission-gateway/README.md"

echo "=== fail-closed on malformed input ==="
# A crashed gate must not be a bypass. The ERR trap returns "ask" if jq fails
# or the payload is unparseable.
for bad_input in 'not json at all' '' '{"tool_input":' '[]'; do
  out=$(printf '%s' "$bad_input" | bash "$GATE" 2>/dev/null || true)
  case "$out" in
    *'"ask"'*) ok "fails closed on malformed input: ${bad_input:-<empty>}" ;;
    *)
      # An empty payload legitimately yields an empty file_path, which is not a
      # protected path — pass-through is correct there, not a bypass.
      if [ -z "$bad_input" ] || [ "$bad_input" = "[]" ]; then
        [ -z "$out" ] && ok "no opinion on empty/irrelevant payload: ${bad_input:-<empty>}" \
                      || bad "unexpected output for ${bad_input:-<empty>}: $out"
      else
        bad "did NOT fail closed on malformed input: ${bad_input:-<empty>} (got: ${out:-<silent>})"
      fi
      ;;
  esac
done

echo "=== fail-closed when the MATCHER itself errors ==="
# Distinct from malformed input above, and the sharper case. `set -e` and the ERR
# trap are both exempt for a command used as an if-condition, so the original
# `if ... | grep -qiE ...; then` could not fail closed on a grep ERROR — a broken
# regex or an unavailable grep read exactly like "no match" and the gate passed
# through. Fail-OPEN, on the one line that makes the decision, in a script whose
# header promises the opposite.
#
# Simulated by shadowing grep on PATH with one that always exits 2, which is what
# grep returns for a genuine error. This needs no source mutation and so keeps
# working as an assertion rather than a one-off experiment.
FAKEBIN=$(mktemp -d)
printf '#!/bin/sh\nexit 2\n' > "$FAKEBIN/grep"
chmod +x "$FAKEBIN/grep"
out=$(jq -nc --arg p ".claude/settings.json" '{tool_input:{file_path:$p},tool_name:"Write"}' \
      | PATH="$FAKEBIN:$PATH" bash "$GATE" 2>/dev/null || true)
if printf '%s' "$out" | grep -q '"ask"' 2>/dev/null; then
  ok "a matcher error asks rather than passing through"
else
  bad "a matcher error did NOT fail closed (got: ${out:-<silent>}) — broken matcher = bypass"
fi
# ...and it must say WHY, or an operator cannot tell this apart from an ordinary
# config-write prompt and will approve it reflexively.
if printf '%s' "$out" | grep -qi 'matcher error' 2>/dev/null; then
  ok "the matcher-error prompt is distinguishable from a normal one"
else
  bad "the matcher-error prompt is indistinguishable from a normal config-write prompt"
fi
rm -rf "$FAKEBIN"

echo "=== manifest registration lint ==="
# The guard is only as good as its wiring. If the manifest stops registering it
# on either tool, every assertion above still passes while the gate never runs
# — coverage of a script nothing invokes.
for tool in Write Edit; do
  if jq -e --arg t "$tool" '
        .hooks.PreToolUse[]
        | select(.matcher == $t)
        | .hooks[]
        | select(.command | test("gate-config-writes"))' "$MANIFEST" >/dev/null 2>&1; then
    ok "manifest registers gate-config-writes on $tool"
  else
    bad "manifest does NOT register gate-config-writes on $tool — the guard never runs"
  fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
