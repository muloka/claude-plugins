#!/usr/bin/env bash
# Tests for check-jj-flags.sh — the hook that rejects a jj flag the installed jj
# does not have.
#
# Requires jj on PATH: the hook's whole design is to ask the real binary what it
# accepts, so a suite that stubbed that out would be testing a different script.
# That does mean these assertions describe the installed jj, which is the point —
# if a future jj restores --allow-new, the deny cases below SHOULD start failing,
# and that is the signal to delete them rather than to work around them.
#
# The must-allow half is the load-bearing half. A hook that denies everything
# passes every deny case, so each one is paired with a case that must pass.
# bash 3.2-safe: no globstar, no associative arrays.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")/../scripts" && pwd)/check-jj-flags.sh"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL+1)); }

if ! command -v jj >/dev/null 2>&1; then
  echo "FAIL: jj not on PATH — this suite cannot verify anything without it"
  exit 1
fi

# Feed a command to the hook, print its raw stdout.
emit() {
  printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | bash "$HOOK" 2>/dev/null || true
}

# decision COMMAND -> "deny" or "allow"
decision() {
  local out
  out=$(emit "$1")
  case "$out" in
    "") printf 'allow' ;;
    *) printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'malformed' ;;
  esac
}

denies() { # denies DESCRIPTION COMMAND
  local d; d=$(decision "$2")
  if [ "$d" = "deny" ]; then ok "$1"; else bad "$1" "got '$d' for: $2"; fi
}

allows() { # allows DESCRIPTION COMMAND
  local d; d=$(decision "$2")
  if [ "$d" = "allow" ]; then ok "$1"; else bad "$1" "got '$d' for: $2"; fi
}

# --- the habit this exists for ---------------------------------------------

# Fixture honesty first: these cases only mean something while the installed jj
# genuinely lacks the flag. If a future jj restores it, this fails with a clear
# message instead of the deny cases failing confusingly — and the answer then is
# to delete them, not to work around them.
if jj git push --help 2>&1 | grep -q -- '--allow-new'; then
  bad "fixture is honest" "the installed jj HAS --allow-new; these cases are obsolete, delete them"
else
  ok "fixture is honest: the installed jj has no --allow-new"
fi

denies "the removed --allow-new is rejected" 'jj git push --bookmark foo --allow-new'
denies "--allow-new alone is rejected" 'jj git push --allow-new'

# The message has to do better than jj's own, which suggests --all — a flag that
# pushes EVERY bookmark and is not what --allow-new did. Steering away from that
# suggestion is most of this hook's value, so it is pinned.
reason=$(emit 'jj git push --allow-new' | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
case "$reason" in
  *"--bookmark <name>"*) ok "message gives the current spelling" ;;
  *) bad "message gives the current spelling" "reason was: $reason" ;;
esac
case "$reason" in
  *"pushes EVERY bookmark"*) ok "message warns off jj's own --all suggestion" ;;
  *) bad "message warns off jj's own --all suggestion" "reason was: $reason" ;;
esac

# --- must-allow: real flags of the installed jj -----------------------------
#
# Without these the suite would pass against a hook that denied unconditionally.
#
# EVERY FLAG NAME HERE IS DERIVED, NOT WRITTEN DOWN. The first cut hardcoded
# `--allow-conflicts` as a must-allow case. CI installs the latest jj release
# while local development was on 0.44.0; that flag is not in the newer binary's
# push surface, and the case failed against a hook that was behaving perfectly
# correctly. The hook's decision is a property of the installed binary, so its
# test has to be one too — a hardcoded list here is exactly the thing that rots,
# which is what the hook was written to stop doing.

allows "a bare push is untouched" 'jj git push'
allows "short flags are not inspected" 'jj git push -b foo'

real_flags=$(jj git push --help 2>&1 \
  | sed -n '/Options:/,$p' \
  | grep -oE '(^|[[:space:]])--[A-Za-z][A-Za-z0-9-]*' \
  | sed 's/^[[:space:]]*//' \
  | sort -u)

if [ -z "$real_flags" ]; then
  bad "flag derivation" "could not read any long flags out of 'jj git push --help'"
else
  ok "derived $(printf '%s\n' "$real_flags" | grep -c .) real flags from the installed jj"
fi

# Every real flag must pass. This is the anti-deny-everything half of the suite,
# and being exhaustive costs nothing here.
flag_fails=0
for f in $real_flags; do
  [ "$(decision "jj git push $f")" = "allow" ] || { flag_fails=$((flag_fails+1)); echo "    unexpectedly denied: $f"; }
done
if [ "$flag_fails" -eq 0 ]; then
  ok "every long flag the installed jj lists is allowed"
else
  bad "every long flag the installed jj lists is allowed" "$flag_fails denied"
fi

# The --flag=value form must resolve to the flag name. Uses a derived flag so it
# cannot name one that has since been removed.
first_flag=$(printf '%s\n' "$real_flags" | head -n 1)
allows "the --flag=value form resolves to the flag name" "jj git push ${first_flag}=somevalue"

# The case that PINS the whole-word match rather than merely exercising it: an
# ABBREVIATION of a real flag. Measured — jj does not infer abbreviated long
# flags, it rejects them outright — so a truncation must be denied. A substring
# test against the help text would allow every one of these, and a mutation to
# substring matching passed this whole suite until this case existed.
#
# The abbreviation is derived by truncating a real flag, and then checked
# against the real set so a truncation that happens to spell another live flag
# is skipped rather than asserted.
abbrev=""
for f in $real_flags; do
  case "$f" in
    --??????*)  # long enough that chopping two characters still leaves a --word
      candidate=$(printf '%s' "$f" | sed 's/..$//')
      case " $(printf '%s' "$real_flags" | tr '\n' ' ') " in
        *" $candidate "*) ;;                  # collides with a real flag; try the next
        *) abbrev=$candidate; break ;;
      esac
      ;;
  esac
done

if [ -n "$abbrev" ]; then
  denies "an abbreviation of a real flag is rejected ($abbrev)" "jj git push $abbrev foo"
else
  bad "abbreviation case" "could not derive a non-colliding abbreviation from the installed jj's flags"
fi

# --- must-allow: everything outside the subcommand in scope -----------------

# The critical false positive. jj's free-text arguments routinely name flags,
# and a general version of this check would deny this repo's own commit
# messages. Scope is what prevents it, so scope is asserted.
allows "a flag named inside a describe message is prose, not a flag" \
  'jj describe -m "the fixture uses jj new --no-edit and drops --allow-new"'
allows "a non-push jj subcommand is out of scope" 'jj git fetch --allow-new'
allows "raw git is not this hook's concern" 'git push --allow-new'

# Everything after a bare -- is positional, so a --word there is a value.
allows "flags after a bare -- terminator are values" 'jj git push --bookmark x -- --allow-new'

# --- compound commands ------------------------------------------------------

denies "an offending clause is found after &&" 'jj git fetch && jj git push --allow-new'
denies "an offending clause is found after a semicolon" 'jj status; jj git push --allow-new'
allows "a compound of only valid clauses passes" 'jj git fetch && jj git push --bookmark foo'

# --- an unknown flag that is not --allow-new --------------------------------
#
# The decision is a property (absent from --help), not a table of known-removed
# flags, so a typo must be caught by the same path.

denies "a typo'd flag is rejected too" 'jj git push --bookmrk foo'
generic=$(emit 'jj git push --bookmrk foo' | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')
case "$generic" in
  *"--help"*) ok "the generic message points at the installed binary's help" ;;
  *) bad "the generic message points at the installed binary's help" "reason was: $generic" ;;
esac

# --- output contract --------------------------------------------------------

out=$(emit 'jj git push --allow-new')
if printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1; then
  ok "a denial is valid JSON with the right event name"
else
  bad "a denial is valid JSON with the right event name" "output was: $out"
fi

# A malformed payload must not produce a denial — silence reads as approval, and
# approving is the only safe answer when the hook cannot understand the input.
if [ -z "$(printf '%s' 'not json at all' | bash "$HOOK" 2>/dev/null || true)" ]; then
  ok "a malformed payload passes through silently"
else
  bad "a malformed payload passes through silently"
fi

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
