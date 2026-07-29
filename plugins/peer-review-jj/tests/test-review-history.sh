#!/usr/bin/env bash
# peer-review-jj's FIRST test suite.
#
# The plugin shipped with zero tests and zero eval cases — 1 command, 2 skills,
# 1 agent, entirely unasserted. That is why a dead mechanism survived unnoticed:
# specialist emergence counts distinct `pattern` values per concern `type` in
# .claude/peer-review/history.jsonl, and every entry ever written had
# `concerns: []`, because nothing told the writer where that array comes from.
#
# These assertions cover the derivation that replaced the prose. They are
# fail-first by construction: append-review-history.sh did not exist when they
# were written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPEND="$SCRIPT_DIR/../scripts/append-review-history.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HIST="$TMP/history.jsonl"

# A realistic aggregate: two severities, two specialist recommendations whose
# field names deliberately differ from the history's (concern/rationale vs
# type/pattern) — the mismatch that made the mapping easy to skip.
AGG='{
  "files_reviewed": ["a.sh", "b.sh"],
  "findings": [
    {"severity":"important","description":"x"},
    {"severity":"important","description":"y"},
    {"severity":"minor","description":"z"}
  ],
  "specialist_recommendations": [
    {"concern":"Security","rationale":"gate scoped to Write/Edit only","files":["a.sh"],"line_ranges":[{"start":1,"end":2}]},
    {"concern":"ErrorHandling","rationale":"ERR trap cannot fire in an if-condition","files":["b.sh"],"line_ranges":[{"start":9,"end":9}]}
  ],
  "verdict": "with_fixes"
}'

run() { printf '%s' "$1" | bash "$APPEND" --revision "${2:-abcd1234}" --timestamp "${3:-1000000000}" --history "$HIST"; }

echo "=== concerns are derived, not hand-written ==="
out=$(run "$AGG")
n=$(printf '%s' "$out" | jq -r '.concerns | length')
if [ "$n" = "2" ]; then
  ok "two specialist recommendations produce two concerns"
else
  bad "two specialist recommendations produce two concerns (got $n)"
fi

# The specific mapping. Asserting only "concerns is non-empty" would pass against
# a writer that emitted the right shape with wrong contents, which is most of the
# way back to the bug.
if [ "$(printf '%s' "$out" | jq -r '.concerns[0].type')" = "Security" ]; then
  ok "concern -> type"
else
  bad "concern -> type (got $(printf '%s' "$out" | jq -r '.concerns[0].type'))"
fi
if [ "$(printf '%s' "$out" | jq -r '.concerns[0].pattern')" = "gate scoped to Write/Edit only" ]; then
  ok "rationale -> pattern"
else
  bad "rationale -> pattern (got $(printf '%s' "$out" | jq -r '.concerns[0].pattern'))"
fi
if [ "$(printf '%s' "$out" | jq -r '.concerns[1].line_ranges[0].start')" = "9" ]; then
  ok "line_ranges carried through"
else
  bad "line_ranges carried through"
fi

echo "=== the regression this suite exists for ==="
# The exact defect: findings present, specialist recommendations present, and the
# history line nonetheless recording concerns: []. Emergence counts that array,
# so an empty one with findings above it means the mechanism is inert.
have_findings=$(printf '%s' "$out" | jq -r '(.findings_count.critical + .findings_count.important + .findings_count.minor) > 0')
have_concerns=$(printf '%s' "$out" | jq -r '(.concerns | length) > 0')
if [ "$have_findings" = "true" ] && [ "$have_concerns" = "true" ]; then
  ok "a review with findings does not record concerns: []"
else
  bad "a review with findings recorded concerns: [] — emergence is inert again"
fi

echo "=== findings_count is tallied by severity ==="
if [ "$(printf '%s' "$out" | jq -r '.findings_count.important')" = "2" ] \
   && [ "$(printf '%s' "$out" | jq -r '.findings_count.minor')" = "1" ] \
   && [ "$(printf '%s' "$out" | jq -r '.findings_count.critical')" = "0" ]; then
  ok "severities tallied: 0 critical / 2 important / 1 minor"
else
  bad "severities tallied (got $(printf '%s' "$out" | jq -c '.findings_count'))"
fi

echo "=== append, never overwrite ==="
# The history is the only record emergence is computed from. A writer that
# truncates loses every prior review while still looking like it worked.
run "$AGG" "second99" >/dev/null
lines=$(grep -c . "$HIST")
if [ "$lines" = "2" ]; then
  ok "second review appends rather than overwriting"
else
  bad "second review appends rather than overwriting (file has $lines line(s))"
fi
if [ "$(tail -1 "$HIST" | jq -r '.revision')" = "second99" ] \
   && [ "$(head -1 "$HIST" | jq -r '.revision')" = "abcd1234" ]; then
  ok "both revisions are present and ordered"
else
  bad "both revisions are present and ordered"
fi

echo "=== one line per entry (JSONL, not pretty-printed) ==="
if [ "$(printf '%s' "$out" | grep -c .)" = "1" ]; then
  ok "entry serialises to a single line"
else
  bad "entry spans multiple lines — the file would stop being JSONL"
fi

echo "=== an empty recommendation set legitimately yields no concerns ==="
CLEAN='{"files_reviewed":["c.sh"],"findings":[],"specialist_recommendations":[],"verdict":"yes"}'
out2=$(run "$CLEAN" "clean001")
if [ "$(printf '%s' "$out2" | jq -r '.concerns | length')" = "0" ] \
   && [ "$(printf '%s' "$out2" | jq -r '.verdict')" = "yes" ]; then
  ok "a clean review records concerns: [] without inventing any"
else
  bad "a clean review records concerns: [] without inventing any"
fi

echo "=== missing keys degrade to empty arrays, not nulls ==="
# A null here serialises into the log and breaks every later jq reader, including
# the emergence count — a poisoned line is worse than a missing one.
SPARSE='{"verdict":"yes"}'
out3=$(run "$SPARSE" "sparse01")
if [ "$(printf '%s' "$out3" | jq -r '.concerns | type')" = "array" ] \
   && [ "$(printf '%s' "$out3" | jq -r '.files_reviewed | type')" = "array" ]; then
  ok "absent keys become arrays, never null"
else
  bad "absent keys became null — downstream jq readers would break"
fi

echo "=== malformed input is rejected before the file is touched ==="
before=$(grep -c . "$HIST")
set +e
printf 'not json' | bash "$APPEND" --revision bad1 --timestamp 1 --history "$HIST" >/dev/null 2>&1
rc=$?
set -e
after=$(grep -c . "$HIST")
if [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then
  ok "invalid JSON exits non-zero and appends nothing"
else
  bad "invalid JSON: rc=$rc, lines went $before -> $after"
fi

echo "=== argument validation ==="
set +e
printf '%s' "$AGG" | bash "$APPEND" --timestamp 1 --history "$HIST" >/dev/null 2>&1
rc_norev=$?
printf '%s' "$AGG" | bash "$APPEND" --revision r --timestamp notanumber --history "$HIST" >/dev/null 2>&1
rc_badts=$?
set -e
[ "$rc_norev" -ne 0 ] && ok "missing --revision is rejected" || bad "missing --revision was accepted"
[ "$rc_badts" -ne 0 ] && ok "non-numeric --timestamp is rejected" || bad "non-numeric --timestamp was accepted"

echo "=== the history file it writes is readable by the emergence query ==="
# Step 5 of the receiving skill counts distinct patterns per type. If that query
# returns nothing against a freshly written file, the format is wrong regardless
# of what the assertions above say.
counted=$(jq -r '.concerns[]? | "\(.type)\t\(.pattern)"' "$HIST" 2>/dev/null | sort -u | grep -c . || true)
if [ "$counted" -ge 2 ]; then
  ok "emergence query reads $counted distinct type/pattern pairs back"
else
  bad "emergence query read $counted pairs — the written format is unusable"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
