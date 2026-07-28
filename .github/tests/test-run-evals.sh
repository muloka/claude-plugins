#!/usr/bin/env bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/run-evals.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# Every scratch tree lives under ONE root that is removed on exit. A suite that
# leaks a temp dir per assertion per run is how a machine ends up with
# thousands of them (see #98). One root, not a registry: half these trees are
# created inside command substitutions, and a registry variable updated in a
# subshell never reaches the trap.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
new_tmp() { d=$(mktemp -d "$TMPROOT/t.XXXXXX"); printf '%s' "$d"; }

# Baseline for the leak check at the bottom of this file. run-evals.sh
# computes its OUT_DIR as "${TMPDIR:-/tmp}/eval-results-$$"; every
# stub-driven invocation below that hits the live path (not --dry-run, not
# --classify) must have ITS OWN TMPDIR pointed at $TMPROOT, or that directory
# lands in the real $TMPDIR and outlives this suite — the same leak class
# #98 fixed for /tmp files. Snapshot what is there BEFORE any of those run;
# pre-existing directories from unrelated runs are not this suite's problem
# and must not be flagged.
REAL_TMPDIR="${TMPDIR:-/tmp}"
BEFORE_LEAK_FILE="$TMPROOT/before-leak.txt"
find "$REAL_TMPDIR" -maxdepth 1 -type d -name 'eval-results-*' 2>/dev/null \
  | sort > "$BEFORE_LEAK_FILE"

# A guard assertion gets its OWN tree, always. Sharing one tree is exactly how
# the block-style assertion went vacuous: an unrelated flow-form case was left
# on disk and tripped exit 7 first, so the assertion passed whether or not the
# parser under test worked at all.
#   $1 = case directory name, stdin = case.yaml body, stdout = tree root
mk_case_tree() {
  root=$(new_tmp)
  mkdir -p "$root/plugins/demo/.claude-plugin" "$root/plugins/demo/evals/$1"
  printf '{"name":"demo","description":"d","version":"0.0.1"}\n' \
    > "$root/plugins/demo/.claude-plugin/plugin.json"
  cat > "$root/plugins/demo/evals/$1/case.yaml"
  printf '%s' "$root"
}

# rc of a guard run against a tree. Never returns the tree's own noise.
guard_rc() {  # $1 = tree, rest = args
  tree="$1"; shift
  set +e
  (cd "$tree" && /bin/bash "$SCRIPT" "$@" --dry-run >/dev/null 2>&1)
  rc=$?
  set -e
  printf '%s' "$rc"
}

# --- discovery: finds case.yaml ---
T=$(new_tmp)
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
E=$(new_tmp)
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

# No plugins/ directory at all — i.e. run from the wrong cwd, the single most
# likely operator error since every documented invocation is relative. `find`
# fails, 2>/dev/null eats the message and pipefail kills the assignment: exit 1
# with no output, and 1 is not in the documented exit contract. Require the
# documented exit 3 AND a message naming the cwd.
NOPLUG=$(new_tmp)
set +e
err=$(cd "$NOPLUG" && /bin/bash "$SCRIPT" --discover-only 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 3 ] && printf '%s' "$err" | grep -q 'plugins/'; then
  ok "missing plugins/ dir aborts with exit 3 and a diagnostic"
else
  bad "missing plugins/ dir aborts with exit 3 and a diagnostic (got rc=$rc: ${err:-<empty>})"
fi

FIX="$(cd "$(dirname "$0")" && pwd)/fixtures/evals"

verdict_of() { /bin/bash "$SCRIPT" --classify "$1" 2>/dev/null | awk -F'\t' 'NR==1{print $5}'; }
verdict_at() { /bin/bash "$SCRIPT" --classify "$1" 2>/dev/null | awk -F'\t' -v n="$2" 'NR==n{print $5}'; }
row_count()  { /bin/bash "$SCRIPT" --classify "$1" 2>/dev/null | grep -c .; }

# Captured CLI output, committed verbatim (fixtures/evals/real/README.md).
# Every other fixture in this suite is hand-written, which means they can only
# ever confirm the author's model of the schema. #102's first fix keyed on
# `num_turns` and every hand-written fixture agreed with it, so the suite was
# green against a field the CLI never emits; this file is the one input that
# can disagree. It is a characterization test until the turn-detail tripwire
# lands — the `num_turns` mutation is what proves it can fail.
REALFIX="$(cd "$(dirname "$0")" && pwd)/fixtures/evals/real"
REAL="$REALFIX/hook-allows-jj-git-and-gh-2026-07-26.json"
#
# `--gate report`, deliberately: this asserts the file CLASSIFIES, not that it
# passes. The captured case scored 1.00 in both arms, so it is a genuine
# NO_GAP, which the default strict gate fails with exit 4 — a correct verdict
# that would mask the thing under test. Report mode treats NO_GAP as a finding,
# so rc 0 here means "no schema error", which is the invariant that breaks when
# the runner keys on a field the CLI does not emit.
set +e
out=$(/bin/bash "$SCRIPT" --classify "$REAL" --gate report 2>/dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'NO_GAP'; then
  ok "a real captured aggregate classifies without error"
else
  bad "a real captured aggregate classifies without error (got rc=$rc: ${out:-<empty>})"
fi

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
#
# Anchored on the delta/score message, not on rc alone. A second tripwire below
# also exits 5, and an assertion keyed only on the code cannot tell them apart —
# that aliasing is what made this invariant untestable in #102's first attempt,
# where deleting the delta/score tripwire outright left the suite green and a
# string-typed delta gated through.
set +e
err=$(/bin/bash "$SCRIPT" --classify "$FIX/nulldelta.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'delta/score'; then
  ok "null delta trips the tripwire (exit 5)"
else
  bad "null delta trips the tripwire (exit 5) (got rc=$rc: ${err:-<empty>})"
fi

# A present-but-string delta is the same disease in the opposite direction:
# jq sorts strings above every number, so "0.0" passes every comparison,
# classifies DISCRIMINATING, and gates GREEN. The tripwire must key on type.
set +e
err=$(/bin/bash "$SCRIPT" --classify "$FIX/stringdelta.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'delta/score'; then
  ok "string-typed delta trips the tripwire (exit 5)"
else
  bad "string-typed delta trips the tripwire (exit 5) (got rc=$rc: ${err:-<empty>})"
fi

# Drift in the SCORE field names, with .delta still numeric. `.score == 0 and
# .score_without == 0` is false when both are null, so the both-arms-zero
# BROKEN detector — the headline defence against a dead run — goes silent and
# the strict gate exits green on a result whose scores are literally null.
# The tripwire must type-check the score fields, not just the delta.
set +e
err=$(/bin/bash "$SCRIPT" --classify "$FIX/driftedscores.json" --gate strict 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'delta/score'; then
  ok "renamed score fields trip the tripwire (exit 5)"
else
  bad "renamed score fields trip the tripwire (exit 5) (got rc=$rc: ${err:-<empty>})"
fi

# Per-run turn detail is required (#102 Gap B). Absence is drift, NOT permission
# to skip the dead-arm check — treating a missing field as "no dead arms found"
# is how a tripwire fails open.
#
# Anchored on wording unique to THIS tripwire, for the reason given above the
# nulldelta case.
NORUNS=$(new_tmp)
jq -nc '{schema_version:"1.0",partial:false,cases:[{name:"no-detail",score:1,score_without:0,delta:1}]}' \
  > "$NORUNS/norundetail.json"
set +e
err=$(/bin/bash "$SCRIPT" --classify "$NORUNS/norundetail.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'per-run turn detail'; then
  ok "missing per-run turn detail trips its own tripwire (exit 5)"
else
  bad "missing per-run turn detail trips its own tripwire (exit 5) (got rc=$rc: ${err:-<empty>})"
fi

# The diagnostic must locate the case. Index, not name: .name may be absent,
# null or empty, and an operator with 16 cases cannot act on "some case".
BADRUNS=$(new_tmp)
jq -nc '{schema_version:"1.0",partial:false,cases:[
  {name:"fine",score:1,score_without:0,delta:1,runs:[{turns:3}],runs_without:[{turns:2}]},
  {score:1,score_without:0,delta:1,runs:[{trace_path:"x"}],runs_without:[{turns:2}]}]}' \
  > "$BADRUNS/badruns.json"
set +e
err=$(/bin/bash "$SCRIPT" --classify "$BADRUNS/badruns.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'case #1' \
   && printf '%s' "$err" | grep -q 'turns'; then
  ok "the turn-detail diagnostic names the case by index and the field"
else
  bad "the turn-detail diagnostic names the case by index and the field (got rc=$rc: ${err:-<empty>})"
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

# A run truncated BEFORE any case finished is a budget breach, not a discovery
# failure. Checking zero-cases first points the operator at #82 and a
# nonexistent glob bug when the actual fix is a larger --max-cost-usd.
set +e
err=$(/bin/bash "$SCRIPT" --classify "$FIX/partialnocases.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 6 ] && printf '%s' "$err" | grep -q 'max-cost-usd'; then
  ok "budget-truncated zero-case run reports the breach (exit 6)"
else
  bad "budget-truncated zero-case run reports the breach (exit 6) (got rc=$rc: ${err:-<empty>})"
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

# Boundary, as the CLI's ARITHMETIC produces it. 7/10 with and 2/10 without is
# a textbook shipping case at exactly the documented threshold, but the CLI
# computes .delta by subtraction and 0.7-0.2 is 0.49999999999999994 in IEEE754.
# A hardcoded literal 0.5 fixture cannot see this: it asserts the taxonomy and
# misses the boundary.
got=$(verdict_of "$FIX/boundary.json" || true)
if [ "$got" = "DISCRIMINATING" ]; then
  ok "delta of 0.5 as the CLI computes it is DISCRIMINATING"
else
  bad "delta of 0.5 as the CLI computes it is DISCRIMINATING (got: ${got:-<empty>})"
fi

# ...and the gate must agree with the verdict. bad_count carries its own copy
# of the comparison, so a fix applied only to the TSV leaves CI failing a case
# the table calls DISCRIMINATING.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/boundary.json" --gate strict >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  ok "strict gate passes the computed-0.5 boundary"
else
  bad "strict gate passes the computed-0.5 boundary (got rc=$rc)"
fi

# A delta that IS literally 0.5 must stay DISCRIMINATING too — the tolerance
# must not be applied in the direction that cuts the boundary case.
got=$(verdict_of "$FIX/boundaryexact.json" || true)
if [ "$got" = "DISCRIMINATING" ]; then
  ok "delta of exactly 0.5 is DISCRIMINATING"
else
  bad "delta of exactly 0.5 is DISCRIMINATING (got: ${got:-<empty>})"
fi

# --- multi-case results: every fixture above holds exactly ONE case, so
# nothing here exercises the TSV's per-case iteration or the gate's cross-case
# counting. A jq anchored to .cases[0] would pass all of them.
n=$(row_count "$FIX/mixed.json" || true)
if [ "$n" = "2" ]; then
  ok "a two-case result prints two TSV rows"
else
  bad "a two-case result prints two TSV rows (got: ${n:-<empty>})"
fi

got=$(verdict_at "$FIX/mixed.json" 1 || true)
if [ "$got" = "DISCRIMINATING" ]; then
  ok "multi-case row 1 classifies DISCRIMINATING"
else
  bad "multi-case row 1 classifies DISCRIMINATING (got: ${got:-<empty>})"
fi

# The row that matters: a BROKEN case sitting BEHIND a healthy one. This is the
# mixed result the taxonomy is built for and the one a .cases[0] gate misses.
got=$(verdict_at "$FIX/mixed.json" 2 || true)
if [ "$got" = "BROKEN" ]; then
  ok "multi-case row 2 classifies BROKEN"
else
  bad "multi-case row 2 classifies BROKEN (got: ${got:-<empty>})"
fi

set +e
/bin/bash "$SCRIPT" --classify "$FIX/mixed.json" --gate strict >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 4 ]; then
  ok "strict gate counts a BROKEN case behind a passing one"
else
  bad "strict gate counts a BROKEN case behind a passing one (got rc=$rc)"
fi

# BROKEN fails in BOTH modes — report downgrades NO_GAP/PARTIAL, never a dead run.
set +e
/bin/bash "$SCRIPT" --classify "$FIX/mixed.json" --gate report >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 4 ]; then
  ok "report gate still fails on a BROKEN case"
else
  bad "report gate still fails on a BROKEN case (got rc=$rc)"
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
BADJSON=$(new_tmp)
printf 'not json at all\n' > "$BADJSON/badjson.json"
set +e
err=$(/bin/bash "$SCRIPT" --classify "$BADJSON/badjson.json" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 65 ] && printf '%s' "$err" | grep -q 'not valid JSON'; then
  ok "malformed JSON reports as invalid (exit 65)"
else
  bad "malformed JSON reports as invalid (exit 65) (got rc=$rc: $err)"
fi

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

D=$(new_tmp)
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

# The CLI's --allow-tools is VARIADIC (`<tools...>`): each tool must be its own
# argv element. Forwarding the operator's raw "Bash,Write" as one element hands
# the CLI a tool name matching nothing, every gated call is denied in BOTH
# arms, and the run comes back 0.00/0.00 — the very outcome the guard exists to
# prevent, produced by the guard's own runner. Assert on the rendered command
# the operator is invited to copy.
cmd=$(cd "$D" && /bin/bash "$SCRIPT" --plugin demo --allow-tools Bash,Write --dry-run 2>&1) || true
if printf '%s' "$cmd" | grep -q -- '--allow-tools Bash Write' \
   && ! printf '%s' "$cmd" | grep -q 'Bash,Write'; then
  ok "dry-run splits a multi-tool grant into separate arguments"
else
  bad "dry-run splits a multi-tool grant into separate arguments (got: $cmd)"
fi

# A case declaring a gated tool absent from the grant must abort loudly,
# rather than scoring both arms 0.00 and reading as "no gap".
NEEDS=$(mk_case_tree needswrite <<'YAML'
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
)
rc=$(guard_rc "$NEEDS" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "ungranted gated tool aborts (exit 7)"
else
  bad "ungranted gated tool aborts (exit 7) (got rc=$rc)"
fi

# ...and the SAME case with the tool granted must run. Without this control the
# assertion above cannot tell "guard fired for the right reason" from "guard
# fires on everything", and a multi-tool grant is exactly what it must accept.
rc=$(guard_rc "$NEEDS" --plugin demo --allow-tools Bash,Write)
if [ "$rc" -eq 0 ]; then
  ok "a granted multi-tool case is not blocked by the guard"
else
  bad "a granted multi-tool case is not blocked by the guard (got rc=$rc)"
fi

# --- #102 Gap A: a gated tool that CANNOT be granted at all ---
#
# `claude plugin eval --help` (2.1.220) documents the operator grant as exactly
# "Bash, Write, Edit, WebFetch, mcp__*". SlashCommand is gated by a different
# mechanism and is absent from that set, so it can never be satisfied by
# --allow-tools. Measured during the Part A probe: a case declared it, the
# guard passed clean, and the CLI printed `denied tools: SlashCommand` at run
# time — both arms denied, both scores zeroed, verdict NO_GAP. That is the
# guard's own failure mode, reached by the tool it does not know about.
#
# The fix is NOT to add SlashCommand to the grantable list: telling the
# operator to pass `--allow-tools SlashCommand` sends them to a flag that
# cannot accept it. It is a separate category — declared, gated, ungrantable,
# therefore unmeasurable — and the abort must say so.
UNGRANTABLE=$(mk_case_tree needsslash <<'YAML'
schema_version: "1.1"
name: needsslash
execution:
  prompt: hello
  allowed_tools: [Bash, SlashCommand]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$UNGRANTABLE" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "an ungrantable gated tool aborts (exit 7)"
else
  bad "an ungrantable gated tool aborts (exit 7) (got rc=$rc)"
fi

# Granting it must NOT rescue the case — that is the whole difference between
# this and the ungranted-tool guard above. If passing --allow-tools SlashCommand
# makes the run proceed, the runner has handed the operator a workaround that
# the CLI will then deny anyway, and the NO_GAP verdict comes back regardless.
rc=$(guard_rc "$UNGRANTABLE" --plugin demo --allow-tools Bash,SlashCommand)
if [ "$rc" -eq 7 ]; then
  ok "granting an ungrantable tool does not rescue the case"
else
  bad "granting an ungrantable tool does not rescue the case (got rc=$rc)"
fi

# The diagnostic must name the tool and say it cannot be granted. rc alone
# cannot distinguish this abort from the ordinary missing-grant one, and an
# operator who reads "add it to --allow-tools" will burn a run finding out.
err=$( (cd "$UNGRANTABLE" && /bin/bash "$SCRIPT" --plugin demo --allow-tools Bash --dry-run 2>&1 >/dev/null) || true )
if printf '%s' "$err" | grep -q 'SlashCommand' \
   && printf '%s' "$err" | grep -qi 'cannot be granted'; then
  ok "the ungrantable diagnostic names the tool and why it cannot be granted"
else
  bad "the ungrantable diagnostic names the tool and why it cannot be granted (got: ${err:-<empty>})"
fi

# Control: the grantable set must still pass untouched. Without this, the
# assertions above are satisfied by a guard that rejects every case.
CONTROL=$(mk_case_tree grantable <<'YAML'
schema_version: "1.1"
name: grantable
execution:
  prompt: hello
  allowed_tools: [Bash, Write, Edit, WebFetch]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$CONTROL" --plugin demo --allow-tools Bash,Write,Edit,WebFetch)
if [ "$rc" -eq 0 ]; then
  ok "the documented grantable set is not rejected as ungrantable"
else
  bad "the documented grantable set is not rejected as ungrantable (got rc=$rc)"
fi

# Block-style YAML must be caught too — it is the layout `eval init` writes,
# so a flow-only guard is blind to precisely the cases it exists to protect.
# Its OWN tree: with a flow-form case left on disk this assertion passes with
# the block parser deleted outright (verified by ablation).
BLOCK=$(mk_case_tree blockstyle <<'YAML'
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
)
rc=$(guard_rc "$BLOCK" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "block-style allowed_tools caught by guard"
else
  bad "block-style allowed_tools caught by guard (got rc=$rc)"
fi

# A YAML comment inside the block list must not truncate it. A comment as the
# FIRST entry yields zero tools and disables the guard completely; the range
# end pattern that stops at "not a - item" matches "#" too.
BLOCKC=$(mk_case_tree blockcomment <<'YAML'
schema_version: "1.1"
name: blockcomment
execution:
  prompt: hello
  allowed_tools:
    # the grader shells out
    - Bash
    - Write
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$BLOCKC" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "comment-first block list still yields its tools"
else
  bad "comment-first block list still yields its tools (got rc=$rc)"
fi

# Comment MID-list: extraction stops there, so everything after it is dropped.
BLOCKM=$(mk_case_tree blockmid <<'YAML'
schema_version: "1.1"
name: blockmid
execution:
  prompt: hello
  allowed_tools:
    - Bash
    # the grader also writes a file
    - Write
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$BLOCKM" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "mid-list comment does not truncate the tool list"
else
  bad "mid-list comment does not truncate the tool list (got rc=$rc)"
fi

# Single-quoted YAML scalars are valid and common. Stripping only double quotes
# leaves 'Write' unmatched by the gated-tool arm and the guard passes silently.
QUOTED=$(mk_case_tree quoted <<'YAML'
schema_version: "1.1"
name: quoted
execution:
  prompt: hello
  allowed_tools: ['Bash', 'Write']
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$QUOTED" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "single-quoted tool names are caught by the guard"
else
  bad "single-quoted tool names are caught by the guard (got rc=$rc)"
fi

# The mirror hazard: an unanchored match on `allowed_tools:` also matches a
# `disallowed_tools:` companion key, so the guard demands the very tool the
# case is trying to DENY. The operator's only way past is to grant it.
DENY=$(mk_case_tree denies <<'YAML'
schema_version: "1.1"
name: denies
execution:
  prompt: hello
  disallowed_tools: [Write]
  allowed_tools: [Bash]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$DENY" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 0 ]; then
  ok "disallowed_tools is not read as a declaration"
else
  bad "disallowed_tools is not read as a declaration (got rc=$rc)"
fi

# The bare layout declares allowed_tools in prompt.md frontmatter (verified
# against the CLI's own frontmatter key set). Discovery was widened to find
# these cases; a guard that requires case.yaml is blind to every one of them.
BARE=$(new_tmp)
mkdir -p "$BARE/plugins/demo/.claude-plugin" "$BARE/plugins/demo/evals/bare/graders"
printf '{"name":"demo","description":"d","version":"0.0.1"}\n' \
  > "$BARE/plugins/demo/.claude-plugin/plugin.json"
cat > "$BARE/plugins/demo/evals/bare/prompt.md" <<'MD'
---
name: bare
allowed_tools: [Bash, Write]
---
Write a file and tell me what happened.
MD
cat > "$BARE/plugins/demo/evals/bare/graders/g.md" <<'MD'
---
type: regex
pattern: hi
---
MD
rc=$(guard_rc "$BARE" --plugin demo --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "prompt.md-layout case is inspected by the guard"
else
  bad "prompt.md-layout case is inspected by the guard (got rc=$rc)"
fi

rc=$(guard_rc "$BARE" --plugin demo --allow-tools Bash,Write)
if [ "$rc" -eq 0 ]; then
  ok "granted prompt.md-layout case runs"
else
  bad "granted prompt.md-layout case runs (got rc=$rc)"
fi

# An eval case path containing a space word-splits an unquoted `for` over the
# discovered list into fragments, none of which holds a case.yaml, so the guard
# inspects NOTHING and the run proceeds ungranted.
SPACED=$(new_tmp)
mkdir -p "$SPACED/plugins/my plugin/.claude-plugin" "$SPACED/plugins/my plugin/evals/space case"
printf '{"name":"my plugin","description":"d","version":"0.0.1"}\n' \
  > "$SPACED/plugins/my plugin/.claude-plugin/plugin.json"
cat > "$SPACED/plugins/my plugin/evals/space case/case.yaml" <<'YAML'
schema_version: "1.1"
name: space case
execution:
  prompt: hello
  allowed_tools: [Bash, Write]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
rc=$(guard_rc "$SPACED" --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "a case path containing a space still reaches the guard"
else
  bad "a case path containing a space still reaches the guard (got rc=$rc)"
fi

# --case is globbed by the CLI against the case's `name:` field, not the
# directory basename (verified against 2.1.220). Scoping on the basename lets
# the two sets go disjoint: the guard inspects nothing, the CLI runs the case
# ungranted, and both arms come back 0.00.
NAMED=$(mk_case_tree needswrite <<'YAML'
schema_version: "1.1"
name: alpha-outcome
execution:
  prompt: hello
  allowed_tools: [Bash, Write]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$NAMED" --plugin demo --case alpha-outcome --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "--case scopes on the case name the CLI matches"
else
  bad "--case scopes on the case name the CLI matches (got rc=$rc)"
fi

# The mirror: a --case that matches the DIRECTORY but no case name selects
# nothing in the CLI. Refusing to spend is right; exit 7 is the wrong reason,
# and it names a tool grant that would not have mattered.
rc=$(guard_rc "$NAMED" --plugin demo --case needswrite --allow-tools Bash)
if [ "$rc" -eq 3 ]; then
  ok "--case matching only a directory name aborts as scoped-to-nothing"
else
  bad "--case matching only a directory name aborts as scoped-to-nothing (got rc=$rc)"
fi

# Scoped to nothing is the #82 disease one level in: indistinguishable from
# guarded-and-clean, and the paid run that follows measures nothing.
rc=$(guard_rc "$NAMED" --plugin demo --case nosuchcase --allow-tools Bash)
if [ "$rc" -eq 3 ]; then
  ok "a --case glob matching nothing aborts (exit 3)"
else
  bad "a --case glob matching nothing aborts (exit 3) (got rc=$rc)"
fi

rc=$(guard_rc "$NAMED" --plugin nosuchplugin --allow-tools Bash)
if [ "$rc" -eq 3 ]; then
  ok "a --plugin matching nothing aborts (exit 3)"
else
  bad "a --plugin matching nothing aborts (exit 3) (got rc=$rc)"
fi

# case_name_of previously ran the declared name through `tr -d " \"'"`, which
# deletes every space and quote ANYWHERE, not just a surrounding pair — so
# `name: my case` was seen by this guard as `mycase`. That desyncs the
# guard's matching from the CLI's own: --case 'my case' (which the CLI WOULD
# match) scoped to nothing here, and --case 'mycase' (which the CLI would
# NOT match) scoped in and passed the guard. Assert the guard scopes on the
# name exactly as declared, internal space intact.
SPACENAME=$(mk_case_tree spacecase <<'YAML'
schema_version: "1.1"
name: my case
execution:
  prompt: hello
  allowed_tools: [Bash, Write]
graders:
  - type: regex
    name: g
    pattern: hi
YAML
)
rc=$(guard_rc "$SPACENAME" --plugin demo --case "my case" --allow-tools Bash)
if [ "$rc" -eq 7 ]; then
  ok "--case with an internal space scopes on the name the CLI matches"
else
  bad "--case with an internal space scopes on the name the CLI matches (got rc=$rc)"
fi

# --- LIVE PATH via a stub `claude` on PATH ---
# Every exit-code test above goes through --classify directly. Without a live
# test, `set -e` killing the runner before classify() is invisible — a green
# suite that cannot fail, which is the exact disease this project exists to
# prevent. These stubs cost nothing and cover the real invocation path.
STUB=$(new_tmp)
mkdir -p "$STUB/bin"
cat > "$STUB/bin/claude" <<'STUBEOF'
#!/usr/bin/env bash
# Emulate the CLI's exit contract: 1 when a case scores under --threshold,
# 2 on --max-cost-usd breach. The real CLI also prints its human summary
# table to STDOUT (verified live on 2.1.220) — the stub must too, or the
# stdout-purity test below can only pass vacuously.
printf 'CASE  WITH  W/OUT (stub table noise)\n'
# Record argv ONE ELEMENT PER LINE. This file is also the "the CLI was
# invoked" sentinel: no file means no spend.
if [ -n "${STUB_ARGV_FILE:-}" ]; then
  : > "$STUB_ARGV_FILE"
  for a in "$@"; do printf '%s\n' "$a" >> "$STUB_ARGV_FILE"; done
fi
outdir=""
prev=""
for a in "$@"; do
  [ "$prev" = "--output-dir" ] && outdir="$a"
  prev="$a"
done
case "${STUB_MODE:-ok}" in
  threshold)
    mkdir -p "$outdir"
    printf '{"schema_version":"1.0","partial":false,"cases":[{"name":"c","score":0.5,"score_without":0,"delta":0.5,"runs":[{"turns":3}],"runs_without":[{"turns":2}]}]}\n' > "$outdir/aggregate-result.json"
    exit 1 ;;
  maxcost)
    mkdir -p "$outdir"
    printf '{"schema_version":"1.0","partial":true,"cases":[{"name":"c","score":1,"score_without":0,"delta":1,"runs":[{"turns":3}],"runs_without":[{"turns":2}]}]}\n' > "$outdir/aggregate-result.json"
    exit 2 ;;
  nooutput)
    # Zero loadable cases: the CLI writes no result at all and exits 0.
    exit 0 ;;
  *)
    mkdir -p "$outdir"
    printf '{"schema_version":"1.0","partial":false,"cases":[{"name":"c","score":1,"score_without":0,"delta":1,"runs":[{"turns":3}],"runs_without":[{"turns":2}]}]}\n' > "$outdir/aggregate-result.json"
    exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/bin/claude"

# A case scoring under 1.0 makes the CLI exit 1. The runner must survive it
# and still classify — otherwise --threshold silently pre-empts the delta gate.
out=$(cd "$D" && PATH="$STUB/bin:$PATH" TMPDIR="$TMPROOT" STUB_MODE=threshold \
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

# The rendered dry-run is a proxy; this is the argv the CLI actually receives.
ARGV="$STUB/argv.txt"
rm -f "$ARGV"
(cd "$D" && PATH="$STUB/bin:$PATH" TMPDIR="$TMPROOT" STUB_ARGV_FILE="$ARGV" \
  /bin/bash "$SCRIPT" --plugin demo --allow-tools Bash,Write >/dev/null 2>&1) || true
if [ -f "$ARGV" ] && grep -qx 'Bash' "$ARGV" && grep -qx 'Write' "$ARGV" \
   && ! grep -q ',' "$ARGV"; then
  ok "each granted tool reaches the CLI as its own argv element"
else
  bad "each granted tool reaches the CLI as its own argv element (got: $( (cat "$ARGV" 2>/dev/null || printf '<no argv>') | tr '\n' ' '))"
fi

# A budget breach is CLI exit 2; .partial must still reach classify as exit 6.
set +e
(cd "$D" && PATH="$STUB/bin:$PATH" TMPDIR="$TMPROOT" STUB_MODE=maxcost \
  /bin/bash "$SCRIPT" --plugin demo >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 6 ]; then
  ok "budget breach reaches the .partial tripwire (exit 6)"
else
  bad "budget breach reaches the .partial tripwire (exit 6) (got rc=$rc)"
fi

# The CLI writes no result directory when it loads zero cases. `find` then
# fails under set -e and the runner dies at exit 1 with a bare `find:` message,
# never reaching classify() and never naming what went wrong.
set +e
err=$(cd "$D" && PATH="$STUB/bin:$PATH" TMPDIR="$TMPROOT" STUB_MODE=nooutput \
  /bin/bash "$SCRIPT" --plugin demo 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 3 ] && printf '%s' "$err" | grep -q 'aggregate-result.json'; then
  ok "a run that writes no result aborts with a diagnosis (exit 3)"
else
  bad "a run that writes no result aborts with a diagnosis (exit 3) (got rc=$rc: ${err:-<empty>})"
fi

# A bad --gate must be rejected BEFORE the CLI is invoked. Validating it inside
# classify() means the typo is caught only after the whole paid run finished:
# the operator pays in full, gets no gate, and exits 64 anyway. rc alone cannot
# see the difference — the sentinel is whether the CLI ran at all.
rm -f "$ARGV"
set +e
(cd "$D" && PATH="$STUB/bin:$PATH" TMPDIR="$TMPROOT" STUB_ARGV_FILE="$ARGV" \
  /bin/bash "$SCRIPT" --plugin demo --gate strcit >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 64 ] && [ ! -f "$ARGV" ]; then
  ok "a bad --gate is rejected before the CLI is invoked"
else
  bad "a bad --gate is rejected before the CLI is invoked (got rc=$rc, cli invoked: $([ -f "$ARGV" ] && printf yes || printf no))"
fi

# stdout must be pure TSV — Task 7 pipes it to a file. The stub prints a fake
# summary table to stdout precisely because the real CLI does; if the runner
# fails to redirect the CLI's stdout, this catches it.
out=$(cd "$D" && PATH="$STUB/bin:$PATH" TMPDIR="$TMPROOT" /bin/bash "$SCRIPT" --plugin demo 2>/dev/null) || true
if printf '%s' "$out" | grep -q 'DISCRIMINATING' \
   && ! printf '%s' "$out" | grep -qE 'discovered|stub table noise'; then
  ok "stdout is pure TSV"
else
  bad "stdout is pure TSV (got: ${out:-<empty>})"
fi

# No stub-driven invocation above may have left a NEW eval-results-* directory
# in the REAL $TMPDIR (see #98: an ~8k-file leak of the same shape). Diff
# against the baseline taken at the top of this file — pre-existing
# directories from other runs are left alone; this fails only on growth this
# suite run caused.
AFTER_LEAK_FILE="$TMPROOT/after-leak.txt"
find "$REAL_TMPDIR" -maxdepth 1 -type d -name 'eval-results-*' 2>/dev/null \
  | sort > "$AFTER_LEAK_FILE"
NEW_LEAK=$(comm -13 "$BEFORE_LEAK_FILE" "$AFTER_LEAK_FILE")
if [ -z "$NEW_LEAK" ]; then
  ok "no new eval-results-* directory leaked into \$TMPDIR"
else
  bad "no new eval-results-* directory leaked into \$TMPDIR (new: $(printf '%s' "$NEW_LEAK" | tr '\n' ' '))"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
