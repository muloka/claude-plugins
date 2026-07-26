#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/run-evals.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# --- discovery: finds case.yaml ---
T=$(mktemp -d)
mkdir -p "$T/plugins/demo/evals/alpha"
touch "$T/plugins/demo/evals/alpha/case.yaml"
out=$(cd "$T" && /bin/bash "$SCRIPT" --discover-only 2>&1) || true
if printf '%s' "$out" | grep -q 'plugins/demo/evals/alpha'; then
  ok "discovers case.yaml"
else
  bad "discovers case.yaml (got: $out)"
fi

# --- discovery: ALSO finds prompt.md (the format `eval init --bare` writes) ---
mkdir -p "$T/plugins/demo/evals/beta/graders"
touch "$T/plugins/demo/evals/beta/prompt.md"
out=$(cd "$T" && /bin/bash "$SCRIPT" --discover-only 2>&1) || true
if printf '%s' "$out" | grep -q 'plugins/demo/evals/beta'; then
  ok "discovers prompt.md format"
else
  bad "discovers prompt.md format (got: $out)"
fi

# --- zero matches must ABORT, not silently pass (#82) ---
E=$(mktemp -d)
mkdir -p "$E/plugins/empty"
set +e
(cd "$E" && /bin/bash "$SCRIPT" --discover-only >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
  ok "zero matches aborts with exit 3"
else
  bad "zero matches aborts with exit 3 (got rc=$rc)"
fi

FIX="$(cd "$(dirname "$0")" && pwd)/fixtures/evals"

verdict_of() { /bin/bash "$SCRIPT" --classify "$1" 2>/dev/null | awk -F'\t' 'NR==1{print $5}'; }

for pair in "discriminating:DISCRIMINATING" "nogap:NO_GAP" "broken:BROKEN" "regression:REGRESSION"; do
  f="${pair%%:*}"; want="${pair##*:}"
  got=$(verdict_of "$FIX/$f.json" || true)
  if [ "$got" = "$want" ]; then
    ok "classifies $f as $want"
  else
    bad "classifies $f as $want (got: ${got:-<empty>})"
  fi
done

# BROKEN must NOT be reported as NO_GAP — a missing --allow-tools grant zeroes
# both arms, and reading that as "no gap" silently deletes the best cases.
# Require a NON-EMPTY verdict: bare != would pass vacuously on empty output
# before classify() even exists (fail-first, third review).
got=$(verdict_of "$FIX/broken.json" || true)
if [ -n "$got" ] && [ "$got" != "NO_GAP" ]; then
  ok "both-arms-zero is never NO_GAP"
else
  bad "both-arms-zero is never NO_GAP (got: ${got:-<empty>})"
fi

# Null delta must abort. jq yields null for a missing path and null sorts BELOW
# every number, so `null < 0` is true — an ungated null files every case as
# REGRESSION while looking like it works.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/nulldelta.json" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 5 ]; then
  ok "null delta trips the tripwire (exit 5)"
else
  bad "null delta trips the tripwire (exit 5) (got rc=$rc)"
fi

# A present-but-string delta is the same disease in the opposite direction:
# jq sorts strings above every number, so "0.0" passes every comparison,
# classifies DISCRIMINATING, and gates GREEN. The tripwire must key on type.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/stringdelta.json" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 5 ]; then
  ok "string-typed delta trips the tripwire (exit 5)"
else
  bad "string-typed delta trips the tripwire (exit 5) (got rc=$rc)"
fi

# A budget-breached run has partial scores; deltas must not be trusted.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/partial.json" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 6 ]; then
  ok "partial run aborts (exit 6)"
else
  bad "partial run aborts (exit 6) (got rc=$rc)"
fi

# strict gate (Part B): anything short of DISCRIMINATING fails.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/nogap.json" --gate strict >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 4 ]; then
  ok "strict gate fails on NO_GAP"
else
  bad "strict gate fails on NO_GAP (got rc=$rc)"
fi

# report gate (Part A): NO_GAP is data, not failure.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/nogap.json" --gate report >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "report gate tolerates NO_GAP"
else
  bad "report gate tolerates NO_GAP (got rc=$rc)"
fi

# PARTIAL is a declared verdict; assert it rather than leaving it untested.
got=$(verdict_of "$FIX/partialgap.json" || true)
if [ "$got" = "PARTIAL" ]; then
  ok "classifies a sub-0.5 delta as PARTIAL"
else
  bad "classifies a sub-0.5 delta as PARTIAL (got: ${got:-<empty>})"
fi

# Boundary: exactly 0.5 ships (>= 0.5 per the spec taxonomy).
got=$(verdict_of "$FIX/boundary.json" || true)
if [ "$got" = "DISCRIMINATING" ]; then
  ok "delta of exactly 0.5 is DISCRIMINATING"
else
  bad "delta of exactly 0.5 is DISCRIMINATING (got: ${got:-<empty>})"
fi

# Zero cases must abort. An empty .cases[] prints nothing and gates green,
# having measured nothing — #82 one level in.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/nocases.json" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
  ok "zero cases in result aborts (exit 3)"
else
  bad "zero cases in result aborts (exit 3) (got rc=$rc)"
fi

# Malformed JSON must report as malformed, not as schema drift.
printf 'not json at all\n' > "$FIX/../badjson.json"
set +e
err=$(/bin/bash "$SCRIPT" --classify "$FIX/../badjson.json" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 65 ] && printf '%s' "$err" | grep -q 'not valid JSON'; then
  ok "malformed JSON reports as invalid (exit 65)"
else
  bad "malformed JSON reports as invalid (exit 65) (got rc=$rc: $err)"
fi
rm -f "$FIX/../badjson.json"

# An unknown gate name must abort, not silently fall through to permissive.
# Require the gate-validation MESSAGE, not just rc 64 — before --classify
# exists, the unknown-argument arm also exits 64, so a bare rc check passes
# vacuously for the wrong reason (fail-first, third review).
set +e
err=$(/bin/bash "$SCRIPT" --classify "$FIX/nogap.json" --gate typo 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 64 ] && printf '%s' "$err" | grep -q -- '--gate must be'; then
  ok "unknown --gate value aborts (exit 64)"
else
  bad "unknown --gate value aborts (exit 64) (got rc=$rc: ${err:-<empty>})"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
