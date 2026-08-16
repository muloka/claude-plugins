#!/usr/bin/env bash
# No shipped revset may use the bare `description("…")` form — it matches nothing.
#
# jj string patterns default to an EXACT match, and jj stores every description
# with a trailing newline. So a bare pattern cannot match a real description
# even when the text is copied perfectly:
#
#     stored description, JSON-quoted:   "side A\n"
#     description("side A")           →  (empty)
#     description("side A\n")         →  1c1806b7458b
#     description(substring:"side A") →  1c1806b7458b
#
# Measured on jj 0.44.0. The failure is SILENT — an empty result set, not an
# error — which is what makes it worth a lint. Four call sites shipped the bare
# form, and in each one "no rows" is indistinguishable from a real answer:
#
#   kaisen SKILL.md      recovering a crashed subagent's change → "never created
#                        a change" → a recoverable task is filed BLOCKED
#   peer-review SKILL.md + peer-review.md, resumability detection → "no review
#                        state exists" → the review restarts from scratch
#
# This lives in .github/tests/ rather than under a plugin because the bug spans
# workspace-jj and peer-review-jj, and the behaviour it pins belongs to jj.
#
# Mechanism, two halves:
#   1. measure jj itself in a throwaway repo, so the reason for the rule is
#      re-verified on every run rather than trusted from this comment
#   2. grep the shipped prose for the bare form in an executable position
#
# Half 1 failing means jj changed, and the prose that calls `substring:`
# "load-bearing" is now wrong — that is a prose fix, not a lint bug.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

command -v jj >/dev/null 2>&1 || { echo "FAIL - jj is not installed; this lint cannot verify anything"; exit 1; }

# --- Half 1: measure jj -------------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

(
  cd "$TMP" || exit 1
  jj git init >/dev/null 2>&1
  jj describe -m "lint probe description" >/dev/null 2>&1
) || { echo "FAIL - could not create probe repo"; exit 1; }

bare=$(cd "$TMP" && jj log --no-graph --ignore-working-copy \
  -r 'description("lint probe description")' -T 'commit_id.short() ++ "\n"' 2>/dev/null)
sub=$(cd "$TMP" && jj log --no-graph --ignore-working-copy \
  -r 'description(substring:"lint probe description")' -T 'commit_id.short() ++ "\n"' 2>/dev/null)

if [ -z "$bare" ]; then
  ok "bare description(\"…\") matches nothing (exact match vs. trailing newline)"
else
  bad "bare description(\"…\") now MATCHES — jj changed; the 'substring: is load-bearing' prose in kaisen/peer-review is stale and must be re-read"
fi

if [ -n "$sub" ]; then
  ok "description(substring:\"…\") matches"
else
  bad "description(substring:\"…\") matches nothing — the fix these lints guard no longer works"
fi

# --- Half 2: lint the shipped prose -------------------------------------------

# Only the executable position (`-r 'description("`) is flagged. Prose that
# NAMES the broken form while explaining the rule is legitimate and must stay
# greppable, so a bare mention in backticks is not a hit.
hits=$(grep -rn -- "-r 'description(\"" "$REPO_ROOT/plugins" 2>/dev/null)
if [ -z "$hits" ]; then
  ok "no plugin ships a bare description(\"…\") revset"
else
  bad "bare description(\"…\") revset shipped — it silently matches nothing:"
  printf '%s\n' "$hits" | sed 's/^/       /'
fi

# Floor: the known call sites must still be using the fixed form. Zero hits
# would otherwise let the lint above pass by finding nothing at all.
fixed=$(grep -rc -- "-r 'description(substring:" "$REPO_ROOT"/plugins/*/skills/*/SKILL.md \
  "$REPO_ROOT"/plugins/*/commands/*.md 2>/dev/null | awk -F: '{ n += $2 } END { print n+0 }')
if [ "$fixed" -ge 4 ]; then
  ok "fixed form still present at $fixed call sites (floor 4)"
else
  bad "only $fixed description(substring:…) call sites found, expected at least 4 — did they move, or regress?"
fi

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
