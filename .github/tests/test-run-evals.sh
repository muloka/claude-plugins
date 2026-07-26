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

D=$(mktemp -d)
mkdir -p "$D/plugins/demo/evals/alpha"
cat > "$D/plugins/demo/evals/alpha/case.yaml" <<'YAML'
schema_version: "1.1"
name: alpha
execution:
  prompt: hello
  allowed_tools: [Bash]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
mkdir -p "$D/plugins/demo/.claude-plugin"
printf '{"name":"demo","description":"d","version":"0.0.1"}\n' \
  > "$D/plugins/demo/.claude-plugin/plugin.json"

cmd=$(cd "$D" && /bin/bash "$SCRIPT" --plugin demo --dry-run 2>&1) || true

for flag in "--ablation with-without" "--allow-tools" "--scaffold" "--output-dir" "CLAUDE_CODE_WALNUT_SPIRE=1"; do
  if printf '%s' "$cmd" | grep -q -- "$flag"; then
    ok "dry-run includes $flag"
  else
    bad "dry-run includes $flag (got: $cmd)"
  fi
done

# --output-dir must land OUTSIDE plugins/, or results trip the #84 version
# lint. Anchor on the flag being PRESENT — a bare not-match is vacuously
# green on empty or error output and can never fail first (third review).
if printf '%s' "$cmd" | grep -q -- '--output-dir' \
   && ! printf '%s' "$cmd" | grep -q -- '--output-dir[= ]*[^ ]*plugins/'; then
  ok "output-dir stays outside plugins/"
else
  bad "output-dir stays outside plugins/ (got: $cmd)"
fi

# A case declaring a gated tool absent from the grant must abort loudly,
# rather than scoring both arms 0.00 and reading as "no gap".
mkdir -p "$D/plugins/demo/evals/needswrite"
cat > "$D/plugins/demo/evals/needswrite/case.yaml" <<'YAML'
schema_version: "1.1"
name: needswrite
execution:
  prompt: hello
  allowed_tools: [Bash, Write]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
set +e
(cd "$D" && /bin/bash "$SCRIPT" --plugin demo --allow-tools Bash --dry-run >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 7 ]; then
  ok "ungranted gated tool aborts (exit 7)"
else
  bad "ungranted gated tool aborts (exit 7) (got rc=$rc)"
fi

# Block-style YAML must be caught too — it is the layout `eval init` writes,
# so a flow-only guard is blind to precisely the cases it exists to protect.
mkdir -p "$D/plugins/demo/evals/blockstyle"
cat > "$D/plugins/demo/evals/blockstyle/case.yaml" <<'YAML'
schema_version: "1.1"
name: blockstyle
execution:
  prompt: hello
  allowed_tools:
    - Bash
    - Write
graders:
  - type: regex
    name: g
    pattern: hi
YAML
set +e
(cd "$D" && /bin/bash "$SCRIPT" --plugin demo --allow-tools Bash --dry-run >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 7 ]; then
  ok "block-style allowed_tools caught by guard"
else
  bad "block-style allowed_tools caught by guard (got rc=$rc)"
fi
rm -rf "$D/plugins/demo/evals/blockstyle" "$D/plugins/demo/evals/needswrite"

# --- LIVE PATH via a stub `claude` on PATH ---
# Every exit-code test above goes through --classify directly. Without a live
# test, `set -e` killing the runner before classify() is invisible — a green
# suite that cannot fail, which is the exact disease this project exists to
# prevent. These stubs cost nothing and cover the real invocation path.
STUB=$(mktemp -d)
mkdir -p "$STUB/bin"
cat > "$STUB/bin/claude" <<'STUBEOF'
#!/usr/bin/env bash
# Emulate the CLI's exit contract: 1 when a case scores under --threshold,
# 2 on --max-cost-usd breach. The real CLI also prints its human summary
# table to STDOUT (verified live on 2.1.220) — the stub must too, or the
# stdout-purity test below can only pass vacuously.
printf 'CASE  WITH  W/OUT (stub table noise)\n'
outdir=""
prev=""
for a in "$@"; do
  [ "$prev" = "--output-dir" ] && outdir="$a"
  prev="$a"
done
mkdir -p "$outdir"
case "${STUB_MODE:-ok}" in
  threshold)
    printf '{"schema_version":"1.0","partial":false,"cases":[{"name":"c","score":0.5,"score_without":0,"delta":0.5}]}\n' > "$outdir/aggregate-result.json"
    exit 1 ;;
  maxcost)
    printf '{"schema_version":"1.0","partial":true,"cases":[{"name":"c","score":1,"score_without":0,"delta":1}]}\n' > "$outdir/aggregate-result.json"
    exit 2 ;;
  *)
    printf '{"schema_version":"1.0","partial":false,"cases":[{"name":"c","score":1,"score_without":0,"delta":1}]}\n' > "$outdir/aggregate-result.json"
    exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/bin/claude"

# A case scoring under 1.0 makes the CLI exit 1. The runner must survive it
# and still classify — otherwise --threshold silently pre-empts the delta gate.
out=$(cd "$D" && PATH="$STUB/bin:$PATH" STUB_MODE=threshold \
  /bin/bash "$SCRIPT" --plugin demo 2>/dev/null) || true
if printf '%s' "$out" | grep -q 'DISCRIMINATING'; then
  ok "live path survives CLI exit 1 and still classifies"
else
  bad "live path survives CLI exit 1 and still classifies (got: ${out:-<empty>})"
fi

# The assembled command must carry --threshold 0, or the above is luck.
cmd=$(cd "$D" && /bin/bash "$SCRIPT" --plugin demo --dry-run 2>/dev/null) || true
if printf '%s' "$cmd" | grep -q -- '--threshold 0'; then
  ok "assembles --threshold 0"
else
  bad "assembles --threshold 0 (got: $cmd)"
fi

# A budget breach is CLI exit 2; .partial must still reach classify as exit 6.
set +e
(cd "$D" && PATH="$STUB/bin:$PATH" STUB_MODE=maxcost \
  /bin/bash "$SCRIPT" --plugin demo >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 6 ]; then
  ok "budget breach reaches the .partial tripwire (exit 6)"
else
  bad "budget breach reaches the .partial tripwire (exit 6) (got rc=$rc)"
fi

# stdout must be pure TSV — Task 7 pipes it to a file. The stub prints a fake
# summary table to stdout precisely because the real CLI does; if the runner
# fails to redirect the CLI's stdout, this catches it.
out=$(cd "$D" && PATH="$STUB/bin:$PATH" /bin/bash "$SCRIPT" --plugin demo 2>/dev/null) || true
if printf '%s' "$out" | grep -q 'DISCRIMINATING' \
   && ! printf '%s' "$out" | grep -qE 'discovered|stub table noise'; then
  ok "stdout is pure TSV"
else
  bad "stdout is pure TSV (got: ${out:-<empty>})"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
