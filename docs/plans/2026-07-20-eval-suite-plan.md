# Eval Suite (issue #79, tranche 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an ablation-gated behavioural eval suite that measures whether these jj plugins actually change model behaviour, plus a triage table for the 16 never-executed `commit-commands-jj` commands.

**Architecture:** Eval cases live at `plugins/<name>/evals/<case>/case.yaml` and run through `claude plugin eval` with `--ablation with-without`, which scores each case twice — with the plugin and without it. A bash runner at `.github/scripts/run-evals.sh` owns the seven environment traps and gates on the *delta* rather than the absolute score, because the harness itself marks zero-gap cases as passing. Classification logic is exposed as a `--classify` mode so it can be tested against JSON fixtures with zero model spend.

**Tech Stack:** bash 3.2, jq, `claude plugin eval` (early access), jj (Jujutsu).

## Global Constraints

- **bash 3.2 is the floor** (CI is `macos-latest`). No `shopt -s globstar`, no associative arrays. Test with `/bin/bash script.sh`, **never** the interactive zsh.
- **This is a jj repo. Never use raw git** — a PreToolUse hook blocks it. Use `jj` and `gh` only. The working copy IS a commit; there is no staging.
- **`CLAUDE_CODE_WALNUT_SPIRE=1` is set on every `claude plugin eval` invocation.** The early-access gate that made the CLI exit 1 without it was measured on 2.1.216; on 2.1.220 `--help` succeeds with the variable unset, so the gate is gone or fires only on a real run. Setting it is harmless — keep setting it, but never use "exits 1 without the var" as a detection heuristic.
- **`--allow-tools Bash` is required on the command line.** `allowed_tools:` in `case.yaml` is necessary but not sufficient; omitting the grant zeroes both arms.
- **House lint style:** `#!/usr/bin/env bash`, `set -euo pipefail`, `ok()`/`bad()` counters, ends with `test "$FAIL" -eq 0`, prints `N passed, M failed`.
- **Every lint is written to FAIL FIRST.** A lint green on its first run has proved nothing. Corollary for negative assertions: anchor on positive evidence — a not-match against empty or error output is vacuously green and can never fail first.
- **CI (#84) requires a version bump** for any byte under `plugins/<name>/`.
- **Write our own prompt text.** netresearch's prompts are CC-BY-SA-4.0; copying them verbatim pulls ShareAlike onto this Apache-2.0 repo.
- **Result JSON fields are flat snake_case:** `.cases[].delta`, `.score`, `.score_without`, `.pass_rate`, `.pass_rate_without`, top-level `.partial`. There is no `.aggregates.*`.

## File Structure

| File | Responsibility |
|---|---|
| `.github/scripts/run-evals.sh` | Discovery, flag assembly, invocation, delta gate. Single entry point. |
| `.github/tests/test-run-evals.sh` | Fail-first suite for the runner. Auto-discovered by CI's existing glob. |
| `.github/tests/fixtures/evals/*.json` | `aggregate-result.json` fixtures for classification tests — no model spend. |
| `plugins/commit-commands-jj/evals/<case>/case.yaml` | Eval cases. |
| `plugins/commit-commands-jj/evals/<case>/scaffold.sh` | Temp jj repo builders. |
| `docs/eval-triage-2026-07.md` | Part A's triage write-up. |

---

### Task 1: Runner skeleton — discovery and zero-match abort

**Files:**
- Create: `.github/scripts/run-evals.sh`
- Create: `.github/tests/test-run-evals.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: `run-evals.sh` supporting `--discover-only` (prints one case dir per line, exit 0) and aborting with exit 3 on zero matches. Later tasks add `--classify` and live invocation.

- [ ] **Step 1: Write the failing test**

Create `.github/tests/test-run-evals.sh`:

```bash
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

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash .github/tests/test-run-evals.sh`
Expected: FAIL — `run-evals.sh` does not exist, all three cases fail.

- [ ] **Step 3: Write minimal implementation**

Create `.github/scripts/run-evals.sh`:

```bash
#!/usr/bin/env bash
# Run plugin eval cases with ablation and gate on the delta.
# bash 3.2-safe: no globstar, no associative arrays.
set -euo pipefail

DISCOVER_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --discover-only) DISCOVER_ONLY=1; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

# Discover case directories. BOTH supported formats: `case.yaml` and the
# `prompt.md` + graders/ layout that `claude plugin eval init --bare` writes.
# A single-format glob would silently skip officially-scaffolded cases (#82).
discover_cases() {
  find plugins \
    \( -path '*/evals/*/case.yaml' -o -path '*/evals/*/prompt.md' \) \
    -type f 2>/dev/null | sed 's#/[^/]*$##' | sort -u
}

CASES=$(discover_cases)

if [ -z "$CASES" ]; then
  printf 'ERROR: no eval cases found under plugins/*/evals/.\n' >&2
  printf 'A glob matching nothing is indistinguishable from passing (#82).\n' >&2
  exit 3
fi

if [ "$DISCOVER_ONLY" -eq 1 ]; then
  printf '%s\n' "$CASES"
  exit 0
fi

# stderr, not stdout — stdout carries the TSV that Task 7 pipes to a file.
printf 'discovered %d case(s)\n' "$(printf '%s\n' "$CASES" | wc -l | tr -d ' ')" >&2
```

- [ ] **Step 4: Run test to verify it passes**

Run: `chmod +x .github/scripts/run-evals.sh && /bin/bash .github/tests/test-run-evals.sh`
Expected: `3 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(evals): runner skeleton with dual-format discovery

Discovers both case.yaml and prompt.md layouts; aborts on zero matches
per #82 (a glob matching nothing looks exactly like passing)."
jj new
```

---

### Task 2: Delta gate — classification with the delta-type tripwire

**Files:**
- Modify: `.github/scripts/run-evals.sh`
- Modify: `.github/tests/test-run-evals.sh`
- Create: `.github/tests/fixtures/evals/discriminating.json`
- Create: `.github/tests/fixtures/evals/nogap.json`
- Create: `.github/tests/fixtures/evals/broken.json`
- Create: `.github/tests/fixtures/evals/regression.json`
- Create: `.github/tests/fixtures/evals/nulldelta.json`
- Create: `.github/tests/fixtures/evals/stringdelta.json`
- Create: `.github/tests/fixtures/evals/partial.json`
- Create: `.github/tests/fixtures/evals/partialgap.json`
- Create: `.github/tests/fixtures/evals/boundary.json`
- Create: `.github/tests/fixtures/evals/nocases.json`

**Interfaces:**
- Consumes: `run-evals.sh` from Task 1.
- Produces: `run-evals.sh --classify <file.json> [--gate strict|report]` printing TSV `name<TAB>score<TAB>score_without<TAB>delta<TAB>verdict`. Verdicts: `DISCRIMINATING`, `PARTIAL`, `NO_GAP`, `REGRESSION`, `BROKEN`. Exit 0 clean; 3 zero cases; 4 gate failure; 5 delta-type tripwire (null or non-numeric); 6 partial run; 64 bad `--gate`; 65 missing or malformed file. Schema drift exits 5 with a diagnostic; it is not a verdict row.

- [ ] **Step 1: Write the fixtures**

Create `.github/tests/fixtures/evals/discriminating.json`:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.15,
 "cases":[{"name":"hook-blocks-raw-git","score":1,"score_without":0,"delta":1,"pass_rate":1,"pass_rate_without":0}]}
```

Create `.github/tests/fixtures/evals/nogap.json`:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.21,
 "cases":[{"name":"describe-noninteractive","score":1,"score_without":1,"delta":0,"pass_rate":1,"pass_rate_without":1}]}
```

Create `.github/tests/fixtures/evals/broken.json`:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.16,
 "cases":[{"name":"missing-tool-grant","score":0,"score_without":0,"delta":0,"pass_rate":0,"pass_rate_without":0}]}
```

Create `.github/tests/fixtures/evals/regression.json`:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.18,
 "cases":[{"name":"plugin-makes-it-worse","score":0,"score_without":1,"delta":-1,"pass_rate":0,"pass_rate_without":1}]}
```

Create `.github/tests/fixtures/evals/nulldelta.json` — the schema-drift case, with the camelCase shape a review report once claimed:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.15,
 "cases":[{"name":"schema-drifted","aggregates":{"delta":1,"score":1,"scoreWithout":0}}]}
```

Create `.github/tests/fixtures/evals/stringdelta.json` — the OTHER drift shape:
a delta that is present but string-typed. jq sorts every string above every
number, so all three comparisons come back false, the case classifies
`DISCRIMINATING`, and the gate exits 0 — schema drift reading as shipping
success, in the one direction (green) the tripwire cannot afford to miss.
Found by the third review running a `"0.0"` delta through classify():

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.15,
 "cases":[{"name":"drifted-to-string","score":"1","score_without":"0","delta":"0.0"}]}
```

Create `.github/tests/fixtures/evals/partial.json`:

```json
{"schema_version":"1.0","partial":true,"cost_usd":5.0,
 "cases":[{"name":"budget-breached","score":1,"score_without":0,"delta":1,"pass_rate":1,"pass_rate_without":0}]}
```

Create `.github/tests/fixtures/evals/partialgap.json` — a sub-0.5 delta, so the
`PARTIAL` verdict is actually exercised rather than merely declared:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.19,
 "cases":[{"name":"weak-gap","score":1,"score_without":0.7,"delta":0.3,"pass_rate":1,"pass_rate_without":0.7}]}
```

Create `.github/tests/fixtures/evals/boundary.json` — delta exactly at the
threshold, pinning the `>=` semantics:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0.17,
 "cases":[{"name":"exactly-half","score":1,"score_without":0.5,"delta":0.5,"pass_rate":1,"pass_rate_without":0.5}]}
```

Create `.github/tests/fixtures/evals/nocases.json` — a structurally valid
result that measured nothing:

```json
{"schema_version":"1.0","partial":false,"cost_usd":0,"cases":[]}
```

- [ ] **Step 2: Write the failing test**

Append to `.github/tests/test-run-evals.sh`, immediately before the final `printf`:

```bash
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `/bin/bash .github/tests/test-run-evals.sh`
Expected: FAIL — `--classify` is an unknown argument (exit 64), and **all 15
new assertions fail** (verified by running this suite against the Task 1
runner). If any new assertion shows `ok` here, it is passing vacuously —
strengthen it before writing a line of implementation.

- [ ] **Step 4: Write minimal implementation**

In `.github/scripts/run-evals.sh`, replace the argument-parsing block with:

```bash
DISCOVER_ONLY=0
CLASSIFY_FILE=""
GATE="strict"

while [ $# -gt 0 ]; do
  case "$1" in
    --discover-only) DISCOVER_ONLY=1; shift ;;
    --classify)      CLASSIFY_FILE="$2"; shift 2 ;;
    --gate)          GATE="$2"; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done
```

Then insert this block immediately after the parsing loop (before discovery, so
`--classify` needs no cases on disk):

```bash
# Classify an aggregate-result.json into verdicts and set the exit code.
# Field paths are FLAT snake_case and verified against a real run:
#   .cases[].delta / .score / .score_without / .pass_rate / .pass_rate_without
#   .partial (top level)
# There is no .aggregates.* — see docs/specs/2026-07-20-eval-suite-design.md.
classify() {
  file="$1"

  if [ ! -f "$file" ]; then
    printf 'ERROR: no such result file: %s\n' "$file" >&2
    exit 65
  fi

  # Malformed JSON must not be misdiagnosed. A `$(jq ...)` inside `[ ... ]`
  # does NOT trip set -e, so without this check a parse error falls through
  # the .partial test and then trips the null-delta tripwire, reporting
  # "schema drift" with total confidence about a file that is simply corrupt.
  if ! jq -e . "$file" >/dev/null 2>&1; then
    printf 'ERROR: %s is not valid JSON\n' "$file" >&2
    exit 65
  fi

  # Zero cases is never success. `.cases[]` over an empty array prints
  # nothing, bad_count is 0, and the gate exits green having measured
  # nothing at all — #82's failure mode, one level in.
  if [ "$(jq -r '.cases | length' "$file")" = "0" ]; then
    printf 'ERROR: result contains zero cases — nothing was measured (#82).\n' >&2
    exit 3
  fi

  # Budget breach: paid graders were skipped, so scores are partial.
  if [ "$(jq -r '.partial // false' "$file")" = "true" ]; then
    printf 'ERROR: run was truncated by --max-cost-usd (.partial=true).\n' >&2
    printf 'Paid graders were skipped; deltas are not trustworthy.\n' >&2
    exit 6
  fi

  # Tripwire: any missing OR non-numeric delta means the result schema moved.
  # null is not the only drift shape: jq sorts every string above every
  # number, so a string "0.0" delta passes every comparison, classifies
  # DISCRIMINATING, and gates green. Key on type — never let a non-number
  # reach a comparison.
  if [ "$(jq -r '[.cases[]? | select((.delta | type) != "number")] | length' "$file")" != "0" ]; then
    printf 'ERROR: a case has a null or non-numeric delta — result schema drift.\n' >&2
    printf 'Expected flat numeric .cases[].delta. Every verdict would be meaningless.\n' >&2
    exit 5
  fi

  jq -r '
    .cases[]?
    | [ .name,
        (.score          | tostring),
        (.score_without  | tostring),
        (.delta          | tostring),
        ( if   (.score == 0 and .score_without == 0) then "BROKEN"
          elif .delta <  0    then "REGRESSION"
          elif .delta == 0    then "NO_GAP"
          elif .delta <  0.5  then "PARTIAL"
          else                     "DISCRIMINATING"
          end )
      ] | @tsv
  ' "$file"

  # Validate the gate name. Without this, any typo falls through to report
  # semantics — silently turning a strict Part B gate permissive and green.
  case "$GATE" in
    strict|report) ;;
    *) printf 'ERROR: --gate must be "strict" or "report", got "%s"\n' "$GATE" >&2
       exit 64 ;;
  esac

  # Gate. strict (Part B): only DISCRIMINATING passes.
  # report (Part A): NO_GAP and PARTIAL are findings, not failures — but
  # BROKEN and REGRESSION always fail, in both modes.
  if [ "$GATE" = "strict" ]; then
    bad_count=$(jq -r '[.cases[] | select((.score == 0 and .score_without == 0) or .delta < 0.5)] | length' "$file")
  else
    bad_count=$(jq -r '[.cases[] | select((.score == 0 and .score_without == 0) or .delta < 0)] | length' "$file")
  fi

  if [ "$bad_count" != "0" ]; then
    printf 'gate(%s): %s case(s) failed\n' "$GATE" "$bad_count" >&2
    exit 4
  fi
}

if [ -n "$CLASSIFY_FILE" ]; then
  classify "$CLASSIFY_FILE"
  exit 0
fi
```

- [ ] **Step 5: Run test to verify it passes**

Run: `/bin/bash .github/tests/test-run-evals.sh`
Expected: `18 passed, 0 failed` (3 discovery + 15 classification — verified by
executing this task's code; if the count differs, reconcile before proceeding)

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(evals): delta gate with null-delta tripwire

Classifies cases by ablation delta, not absolute score — the harness
marks zero-gap cases PASS, which is the opposite of what we want.

Guards: both-arms-zero is BROKEN (a missing --allow-tools grant) and
never NO_GAP; null or non-numeric deltas abort — jq sorts null below and
strings above every number, so an ungated null files every case as
REGRESSION and an ungated string as DISCRIMINATING, both while looking
correct."
jj new
```

---

### Task 3: Live invocation — flag assembly and the tool-grant guard

**Files:**
- Modify: `.github/scripts/run-evals.sh`
- Modify: `.github/tests/test-run-evals.sh`

**Interfaces:**
- Consumes: `discover_cases()` and `classify()`.
- Produces: `run-evals.sh [--plugin <name>] [--case <glob>] [--runs <n>] [--gate strict|report] [--keep-temp] [--max-cost-usd <n>] [--dry-run]`. `--dry-run` prints the assembled command without executing — the seam that makes flag assembly testable without spend.

- [ ] **Step 1: Write the failing test**

Append to `.github/tests/test-run-evals.sh` before the final `printf`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash .github/tests/test-run-evals.sh`
Expected: FAIL — `--plugin`, `--dry-run`, `--allow-tools` are unknown
arguments (exit 64), and **all 12 new assertions fail**. If any new assertion
shows `ok` here, it is passing vacuously — strengthen it before writing a
line of implementation.

- [ ] **Step 3: Write minimal implementation**

Extend the argument loop in `.github/scripts/run-evals.sh`:

```bash
DISCOVER_ONLY=0
CLASSIFY_FILE=""
GATE="strict"
PLUGIN=""
CASE_GLOB=""
RUNS=""
KEEP_TEMP=0
MAX_COST="5"
ALLOW_TOOLS="Bash"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --discover-only) DISCOVER_ONLY=1; shift ;;
    --classify)      CLASSIFY_FILE="$2"; shift 2 ;;
    --gate)          GATE="$2"; shift 2 ;;
    --plugin)        PLUGIN="$2"; shift 2 ;;
    --case)          CASE_GLOB="$2"; shift 2 ;;
    --runs)          RUNS="$2"; shift 2 ;;
    --allow-tools)   ALLOW_TOOLS="$2"; shift 2 ;;
    --max-cost-usd)  MAX_COST="$2"; shift 2 ;;
    --keep-temp)     KEEP_TEMP=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done
```

Append after the discovery block:

```bash
# Scope the guard to what this invocation will actually run. Scanning every
# discovered case makes an unrelated plugin's Write-requiring case abort a run
# that never touches it.
SCOPED=""
for case_dir in $CASES; do
  case "$case_dir" in
    plugins/${PLUGIN}/*|plugins/*) : ;;
  esac
  if [ -n "$PLUGIN" ]; then
    case "$case_dir" in plugins/"$PLUGIN"/*) ;; *) continue ;; esac
  fi
  if [ -n "$CASE_GLOB" ]; then
    # shellcheck disable=SC2254
    case "$(basename "$case_dir")" in $CASE_GLOB) ;; *) continue ;; esac
  fi
  SCOPED="$SCOPED$case_dir
"
done

# Guard: every gated tool a case declares must appear in the grant. Without
# this, the agent cannot call the tool, BOTH arms score 0.00, and the delta
# reads 0.00 — which the gate would otherwise interpret as "measures the
# model, cut the case". That silently deletes the best cases in the suite.
for case_dir in $SCOPED; do
  [ -f "$case_dir/case.yaml" ] || continue
  # Extract BOTH YAML forms. Flow (`[Bash, Write]`) and block sequence
  # (`- Bash` on following lines). A block-form-blind guard misses exactly the
  # layout `claude plugin eval init` scaffolds — i.e. the case it exists for.
  declared=$( { sed -n 's/.*allowed_tools:[[:space:]]*\[\(.*\)\].*/\1/p' "$case_dir/case.yaml" | tr ',' '\n'
                sed -n '/allowed_tools:[[:space:]]*$/,/^[[:space:]]*[^[:space:]-]/ s/^[[:space:]]*-[[:space:]]*//p' "$case_dir/case.yaml"
              } | tr -d ' "' | grep -v '^$' || true )
  for tool in $declared; do
    case "$tool" in
      Bash|Write|Edit|WebFetch|mcp__*)
        # Exact match against the grant list — an unanchored grep lets
        # `--allow-tools BashOutput` satisfy a requirement for `Bash`.
        if ! printf '%s' "$ALLOW_TOOLS" | tr ', ' '\n\n' | grep -qx "$tool"; then
          printf 'ERROR: %s declares gated tool "%s" but --allow-tools is "%s".\n' \
            "$case_dir" "$tool" "$ALLOW_TOOLS" >&2
          printf 'Both ablation arms would score 0.00 and read as "no gap".\n' >&2
          exit 7
        fi
        ;;
    esac
  done
done

TARGET="plugins/${PLUGIN}"
[ -n "$PLUGIN" ] || TARGET="plugins"
OUT_DIR="${TMPDIR:-/tmp}/eval-results-$$"

# --threshold 0 is LOAD-BEARING. It defaults to 1.0, so the CLI exits 1 on any
# case scoring below 1.00 — which, under `set -e`, kills this script before
# classify() ever runs. The delta gate would be permanently unreachable, and
# every case the sweep exists to measure scores below 1.00 by definition.
set -- "$TARGET" --ablation with-without --scaffold \
  --allow-tools "$ALLOW_TOOLS" --threshold 0 \
  --output-dir "$OUT_DIR" --max-cost-usd "$MAX_COST"
[ -z "$CASE_GLOB" ] || set -- "$@" --case "$CASE_GLOB"
[ -z "$RUNS" ]      || set -- "$@" --runs "$RUNS"
[ "$KEEP_TEMP" -eq 0 ] || set -- "$@" --keep-temp

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'CLAUDE_CODE_WALNUT_SPIRE=1 JJ_USER=%s JJ_EMAIL=%s claude plugin eval %s\n' \
    "${JJ_USER:-eval}" "${JJ_EMAIL:-eval@example.com}" "$*"
  exit 0
fi

# Capture the CLI's exit code rather than letting set -e act on it. Exit 2 is
# the documented --max-cost-usd breach, which must reach classify() so the
# .partial tripwire can report it; anything above 2 is a real failure.
# The CLI prints its human summary table to STDOUT (verified live, 2.1.220);
# send it to stderr — stdout belongs to the TSV that Task 7 pipes to a file.
eval_rc=0
CLAUDE_CODE_WALNUT_SPIRE=1 \
JJ_USER="${JJ_USER:-eval}" \
JJ_EMAIL="${JJ_EMAIL:-eval@example.com}" \
  claude plugin eval "$@" 1>&2 || eval_rc=$?

if [ "$eval_rc" -gt 2 ]; then
  printf 'ERROR: claude plugin eval failed (rc=%s)\n' "$eval_rc" >&2
  exit "$eval_rc"
fi

RESULT="$(find "$OUT_DIR" -name aggregate-result.json | head -1)"
# Task 7 reads per-grader results (the exercised precondition) from this
# file; print the path where a human can find it.
printf 'result JSON: %s\n' "$RESULT" >&2
classify "$RESULT"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `/bin/bash .github/tests/test-run-evals.sh`
Expected: `30 passed, 0 failed` (18 prior + 12 new — verified by executing
this task's code)

If the count differs, reconcile before proceeding — a drifting expected count
is how a suite quietly stops asserting what it claims.

- [ ] **Step 5: Verify bash 3.2 compatibility explicitly**

Run: `/bin/bash --version | head -1 && /bin/bash -n .github/scripts/run-evals.sh && echo "SYNTAX OK"`
Expected: `GNU bash, version 3.2.57` and `SYNTAX OK`.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(evals): live invocation with tool-grant guard

Assembles the flag set that owns the harness's seven traps, and refuses
to run when a case declares a gated tool the grant omits — that
combination zeroes both arms and reads as 'no gap'."
jj new
```

---

### Task 4: Exemplar case — hook-blocks-raw-git

**Files:**
- Create: `plugins/commit-commands-jj/evals/hook-blocks-raw-git/case.yaml`
- Create: `plugins/commit-commands-jj/evals/hook-blocks-raw-git/scaffold.sh`
- Modify: `.gitignore`
- Modify: `plugins/commit-commands-jj/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: the runner from Task 3.
- Produces: the committed schema exemplar every later case is copied from. Measured Δ +1.00 (with 1.00 / without 0.00), reproduced independently three times.

- [ ] **Step 1: Write the scaffold**

Create `plugins/commit-commands-jj/evals/hook-blocks-raw-git/scaffold.sh`:

```bash
#!/usr/bin/env bash
# Build a throwaway jj repo for the case. Hardened per netresearch's MIT
# pattern: paginate=never and editor=true, so an accidental interactive
# invocation no-ops instead of hanging the run.
set -euo pipefail

export JJ_USER="${JJ_USER:-eval}"
export JJ_EMAIL="${JJ_EMAIL:-eval@example.com}"

mkdir -p .jjconfig
cat > .jjconfig/config.toml <<'TOML'
[ui]
paginate = "never"
editor = "true"
TOML
export JJ_CONFIG="$PWD/.jjconfig/config.toml"

jj git init . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
```

- [ ] **Step 2: Write the case**

Create `plugins/commit-commands-jj/evals/hook-blocks-raw-git/case.yaml`:

```yaml
schema_version: "1.1"
name: hook-blocks-raw-git
description: >
  block-raw-git.sh must deny a raw git command inside a jj repo.
  Ablation-verified: with 1.00 / without 0.00, delta +1.00.
tags: [commit-commands-jj, hook, invariant]
context:
  scaffold_script: scaffold.sh
execution:
  prompt: |
    Run the shell command `git status` in this repository and tell me
    exactly what happened.
  max_turns: 6
  timeout_seconds: 300
  allowed_tools: [Bash]
runs: 2
graders:
  - type: regex
    name: reports-blocked
    pattern: "(BLOCKED|blocked|not allowed|denied)"
    match: contains
    weight: 1
```

- [ ] **Step 3: Ignore results and bump the version**

Append to `.gitignore`:

```
**/evals/results/
```

**The `**/` prefix is required.** A gitignore pattern containing a mid-string
slash is anchored to the file's own directory, so a bare `evals/results/` would
match only a root-level directory that never exists — while
`plugins/commit-commands-jj/evals/results/`, the exact path that trips the #84
lint, stays fully tracked. Verified under jj:

```
pattern=evals/results/      plugins/foo/evals/results IGNORED? NO
pattern=**/evals/results/   plugins/foo/evals/results IGNORED? YES
```

jj auto-snapshots the working copy, so if results ever land before this entry
is correct they are already tracked and the pattern will not retroactively
apply. Remediate with `jj file untrack 'glob:**/evals/results/**'`.

In `plugins/commit-commands-jj/.claude-plugin/plugin.json`, change `"version": "0.1.1"` to `"version": "0.2.0"`. Required by #84 for any byte under `plugins/<name>/`.

- [ ] **Step 4: Run the case and verify the delta**

Run:
```bash
chmod +x plugins/commit-commands-jj/evals/hook-blocks-raw-git/scaffold.sh
/bin/bash .github/scripts/run-evals.sh --plugin commit-commands-jj \
  --case 'hook-blocks-raw-git' --gate strict
```
Expected: a TSV row ending `DISCRIMINATING`, exit 0. If it prints `BROKEN`, the tool grant is wrong; if `NO_GAP`, the hook is not firing.

- [ ] **Step 5: Verify the version-bump lint is satisfied**

Run:
```bash
BASE=$(mktemp -d)
jj --ignore-working-copy file list -r 'trunk()' 'glob:plugins/*/.claude-plugin/plugin.json' \
  | while read -r p; do
      mkdir -p "$BASE/$(dirname "$p")"
      jj --ignore-working-copy file show -r 'trunk()' "$p" > "$BASE/$p"
    done
CHANGED_FILES=$(jj --ignore-working-copy diff --from 'trunk()' --name-only) \
  BASE_DIR="$BASE" /bin/bash .github/scripts/require-version-bump.sh
```
Expected: exit 0.

**`BASE_DIR=.` does not work** — it resolves the base manifest to the same file
as the head manifest, so `base_ver == head_ver` always and the lint fails
unconditionally, even with the bump correctly applied. The script needs a real
base tree, which the block above materialises from `trunk()`.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(evals): hook-blocks-raw-git exemplar case

First ablation-verified case: delta +1.00, reproduced three times.
Doubles as the committed schema exemplar — the spec deliberately does
not restate the schema in prose, because its first draft got
regex.target wrong.

Bumps commit-commands-jj to 0.2.0 (#84) and gitignores evals/results/."
jj new
```

---

### Task 5: Remaining hook and invariant cases

**Files:**
- Create: `plugins/commit-commands-jj/evals/hook-blocks-git-internals/{case.yaml,scaffold.sh}`
- Create: `plugins/commit-commands-jj/tests/test-block-raw-git-gating.sh` (the #45 invariant as a layer-2 test, not an eval — see Step 2)
- Create: `plugins/commit-commands-jj/evals/hook-allows-jj-git-and-gh/{case.yaml,scaffold.sh}`
- Modify: `plugins/commit-commands-jj/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: the Task 4 exemplar (copy its shape).
- Produces: three more cases, each either ablation-verified or cut with the measurement recorded.

- [ ] **Step 1: Case — git internals**

Create `plugins/commit-commands-jj/evals/hook-blocks-git-internals/scaffold.sh` — identical to Task 4's scaffold (repeated deliberately; do not symlink, cases must stand alone).

```bash
#!/usr/bin/env bash
set -euo pipefail
export JJ_USER="${JJ_USER:-eval}"
export JJ_EMAIL="${JJ_EMAIL:-eval@example.com}"
mkdir -p .jjconfig
cat > .jjconfig/config.toml <<'TOML'
[ui]
paginate = "never"
editor = "true"
TOML
export JJ_CONFIG="$PWD/.jjconfig/config.toml"
jj git init . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
```

Create `plugins/commit-commands-jj/evals/hook-blocks-git-internals/case.yaml`:

```yaml
schema_version: "1.1"
name: hook-blocks-git-internals
description: >
  The hook's second, separately-coded branch: .git/ access and git plumbing
  (rev-parse, config) carry their own deny message.
tags: [commit-commands-jj, hook, invariant]
context:
  scaffold_script: scaffold.sh
execution:
  prompt: |
    Print the current commit hash by running `git rev-parse HEAD`, and
    tell me exactly what happened.
  max_turns: 6
  timeout_seconds: 300
  allowed_tools: [Bash]
runs: 2
graders:
  - type: regex
    name: reports-blocked
    pattern: "(BLOCKED|blocked|not allowed|denied|internals)"
    match: contains
    weight: 1
```

- [ ] **Step 2: Case — non-jj repo pass-through (#45) — DO NOT WRITE AS AN EVAL**

The #45 invariant is that outside a jj repo the hook passes git through.
Blocking git in a non-jj project is collateral damage, not the design.

**This cannot be an eval, and the reasoning matters more than the case.** The
grader would assert the *absence* of a deny. But the `without` arm has no hook
either, so it also produces no deny — both arms pass, Δ = 0, and the case
reports `NO_GAP` no matter what the hook does. It is structurally incapable of
distinguishing "the hook correctly passed git through" from "there is no hook".
Spending on it would buy a number that cannot mean anything.

Worse in practice: the scaffold cannot run `git init` (the session hook blocks
raw git), so the sandbox would be a bare directory where `git status` fails
with "not a repository" in both arms — failing for a third reason unrelated to
the invariant.

**Write it as a layer-2 shell test instead.** The hook is a pure function from
JSON stdin to JSON stdout; testing it needs no model at all. Create
`plugins/commit-commands-jj/tests/test-block-raw-git-gating.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HOOK="$(cd "$(dirname "$0")/../scripts" && pwd)/block-raw-git.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# Inside a jj repo: raw git is denied.
JJ_DIR=$(mktemp -d); mkdir -p "$JJ_DIR/.jj"
out=$(printf '{"cwd":"%s","tool_input":{"command":"git status"}}' "$JJ_DIR" | /bin/bash "$HOOK")
if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
  ok "denies raw git inside a jj repo"
else
  bad "denies raw git inside a jj repo (got: $out)"
fi

# Outside a jj repo: passes through silently (#45). Anchor in a NON-jj temp
# dir — the dev checkout is itself a jj repo, so a relative cwd would walk up
# into the real .jj and invert this test.
PLAIN=$(mktemp -d)
out=$(printf '{"cwd":"%s","tool_input":{"command":"git status"}}' "$PLAIN" | /bin/bash "$HOOK")
if [ -z "$out" ]; then
  ok "passes git through outside a jj repo (#45)"
else
  bad "passes git through outside a jj repo (#45) (got: $out)"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
```

Run: `/bin/bash plugins/commit-commands-jj/tests/test-block-raw-git-gating.sh`
Expected: `2 passed, 0 failed`. CI auto-discovers it via the existing
`*/tests/test-*.sh` glob, and it also closes the "no tests/ directory" gap
that Task 8 otherwise only files as an issue.

- [ ] **Step 3: Case — jj git and gh survive the lookahead**

Create `plugins/commit-commands-jj/evals/hook-allows-jj-git-and-gh/scaffold.sh` — identical to Task 4's.

```bash
#!/usr/bin/env bash
set -euo pipefail
export JJ_USER="${JJ_USER:-eval}"
export JJ_EMAIL="${JJ_EMAIL:-eval@example.com}"
mkdir -p .jjconfig
cat > .jjconfig/config.toml <<'TOML'
[ui]
paginate = "never"
editor = "true"
TOML
export JJ_CONFIG="$PWD/.jjconfig/config.toml"
jj git init . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
```

Create `plugins/commit-commands-jj/evals/hook-allows-jj-git-and-gh/case.yaml`:

```yaml
schema_version: "1.1"
name: hook-allows-jj-git-and-gh
description: >
  Regression guard on the subtlest line in the hook — the negative lookahead
  that must let `jj git ...` and `gh ...` through while blocking bare git.
tags: [commit-commands-jj, hook, invariant]
context:
  scaffold_script: scaffold.sh
execution:
  prompt: |
    Run `jj git remote list` in this repository and tell me exactly what
    happened.
  max_turns: 6
  timeout_seconds: 300
  allowed_tools: [Bash]
runs: 2
graders:
  - type: tool_used
    name: jj-git-ran
    tool: Bash
    input_match: "jj git remote"
    min: 1
    weight: 1
  - type: regex
    name: not-blocked
    pattern: "(BLOCKED|not allowed)"
    match: not_contains
    weight: 1
```

- [ ] **Step 4: Ablation-check the two evals**

Run:
```bash
for c in hook-blocks-git-internals hook-allows-jj-git-and-gh; do
  chmod +x "plugins/commit-commands-jj/evals/$c/scaffold.sh" 2>/dev/null || true
  /bin/bash .github/scripts/run-evals.sh --plugin commit-commands-jj --case "$c" --gate report
done
```
Expected: a verdict per case. **Do not assume all three ship.** For any case returning `NO_GAP`, cut it and record the measured scores in the commit message. For `BROKEN`, fix the tool grant and re-run — never record BROKEN as a finding.

Note `hook-allows-jj-git-and-gh` partly asserts the *absence* of a deny, so its
`without` arm may also pass and yield `NO_GAP`. Its `jj-git-ran` grader is what
gives it any discriminating power. If it returns `NO_GAP`, move it to the
layer-2 suite from Step 2 alongside the #45 gating test — the hook is a pure
stdin/stdout function and testing it needs no model.

- [ ] **Step 5: Bump the version**

In `plugins/commit-commands-jj/.claude-plugin/plugin.json`, change `"version": "0.2.0"` to `"version": "0.3.0"`.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(evals): hook invariant cases

Adds git-internals, non-jj pass-through (#45), and the jj-git/gh
lookahead guard. Records measured deltas per case; non-discriminating
cases cut with their scores noted rather than kept as decoration."
jj new
```

---

### Task 6: Part A — command triage cases

**Files:**
- Create: `plugins/commit-commands-jj/evals/cmd-<name>/case.yaml` × 16
- Create: `.github/scripts/gen-command-cases.sh`
- Modify: `plugins/commit-commands-jj/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: the runner and exemplar.
- Produces: 16 cases named `cmd-<command>`, each invoking its command literally and carrying an invocation precondition.

- [ ] **Step 1: Write the generator**

The 16 cases differ only in command name and prompt, so generate them rather than hand-writing 16 near-identical files. Create `.github/scripts/gen-command-cases.sh`:

```bash
#!/usr/bin/env bash
# Generate one triage case per commit-commands-jj command.
# bash 3.2-safe: parallel-array lookup, no associative arrays.
set -euo pipefail

PLUGIN_DIR="plugins/commit-commands-jj"
EVAL_DIR="$PLUGIN_DIR/evals"

# command:prompt pairs. Prompts contain the LITERAL slash-command invocation —
# the model never reaches for a command on its own (measured: 0 Skill and 0
# SlashCommand calls on task-phrased prompts), so a natural-language prompt
# would measure the base model and report a null result it could not avoid.
PAIRS="
describe:/describe record that notes.txt was added
commit:/commit finalize this change
new:/new start a change for the parser work
squash:/squash fold this into its parent
abandon:/abandon discard this change
sync:/sync bring this change up to date with trunk
absorb:/absorb move these edits into the changes that touched these lines
edit:/edit move the working copy to the previous change
evolog:/evolog show how this change evolved
show:/show inspect the current revision
op-show:/op-show inspect the most recent operation
undo:/undo revert the last operation
tag-list:/tag-list list the tags
clean_stale:/clean_stale clean up stale bookmarks and workspaces
commit-push-pr:/commit-push-pr ship this as a pull request
finish:/finish wrap up this development work
"

printf '%s\n' "$PAIRS" | while IFS=: read -r cmd prompt; do
  [ -n "$cmd" ] || continue
  dir="$EVAL_DIR/cmd-$cmd"
  mkdir -p "$dir"

  cat > "$dir/scaffold.sh" <<'SCAFFOLD'
#!/usr/bin/env bash
set -euo pipefail
export JJ_USER="${JJ_USER:-eval}"
export JJ_EMAIL="${JJ_EMAIL:-eval@example.com}"
mkdir -p .jjconfig
cat > .jjconfig/config.toml <<'TOML'
[ui]
paginate = "never"
editor = "true"
TOML
export JJ_CONFIG="$PWD/.jjconfig/config.toml"
jj git init . >/dev/null 2>&1
printf 'alpha\n' > notes.txt
SCAFFOLD
  chmod +x "$dir/scaffold.sh"

  cat > "$dir/case.yaml" <<YAML
schema_version: "1.1"
name: cmd-$cmd
description: >
  Triage: does /$cmd change behaviour versus not having the plugin?
  The invoked-command grader is a VALIDITY PRECONDITION at weight 0 — if it
  fails the result is "did not exercise the command", which is neither
  "earns its keep" nor "no measurable gap". It must never contribute to the
  score: the command does not exist in the without arm, so a scored
  precondition manufactures the delta.
tags: [commit-commands-jj, triage]
context:
  scaffold_script: scaffold.sh
execution:
  prompt: |
    $prompt
  max_turns: 10
  timeout_seconds: 300
  allowed_tools: [Bash, Read, Skill, SlashCommand]
runs: 3
graders:
  # VALIDITY PRECONDITION, not a scored grader. In the without arm the slash
  # command does not exist, so a scored invoked-command grader fails there
  # mechanically — manufacturing a guaranteed delta for every exercised
  # command (the null-control disease this suite exists to prevent) and
  # filing unexercised commands as NO_GAP. Weight 0 keeps the pass/fail
  # record in runs[].graders[] (Task 7 reads it) without letting plugin
  # EXISTENCE masquerade as prose value.
  - type: tool_used
    name: invoked-command
    tool: SlashCommand
    min: 1
    weight: 0
  - type: tool_used
    name: no-raw-git
    tool: Bash
    # Command-position anchor: match `git <verb>` only at line start or after
    # a separator (; & |). The previous (^|[^a-z]) matched the SPACE in
    # `jj git push` — failing /commit-push-pr and /finish precisely when the
    # model follows their documented `jj git push` workflow — and matched
    # substrings inside quoted text (`jj describe -m "add git log parser"`).
    # Only syntax common to ERE and JS RegExp, so the grep -E check in Step 2
    # verifies the same pattern the grader engine compiles.
    input_match: "(^ *|[;&|] *)git (commit|add|status|log|diff|push)"
    min: 0
    max: 0
    weight: 1
YAML
done

printf 'generated %d case(s) under %s\n' \
  "$(find "$EVAL_DIR" -maxdepth 1 -name 'cmd-*' -type d | wc -l | tr -d ' ')" "$EVAL_DIR"
```

- [ ] **Step 2: Generate, verify count, and verify the guard regex offline**

Run:
```bash
/bin/bash .github/scripts/gen-command-cases.sh
find plugins/commit-commands-jj/evals -maxdepth 1 -name 'cmd-*' -type d | wc -l
```
Expected: `generated 16 case(s)` and `16`.

The negative grader must not match the plugin's own documented workflow —
`/commit-push-pr` and `/finish` instruct `jj git push`, and `min: 0, max: 0`
means any match fails the case. Verify the regex offline (free), via a script
file so the session's own raw-git hook does not block the literal test
strings:

```bash
cat > /tmp/check-regex.sh <<'CHECK'
#!/usr/bin/env bash
set -euo pipefail
RE='(^ *|[;&|] *)git (commit|add|status|log|diff|push)'
while IFS= read -r s; do
  printf '%s' "$s" | grep -qE "$RE" && { echo "FALSE-POSITIVE: $s"; exit 1; }
done <<'NEG'
jj git push
jj git push --bookmark my-feature
jj git push --change @-
jj git push --deleted
jj describe -m "add git log parser"
echo "git status"
NEG
while IFS= read -r s; do
  printf '%s' "$s" | grep -qE "$RE" || { echo "MISS: $s"; exit 1; }
done <<'POS'
git push
git status
cd x && git commit -m hi
git add .; git push
POS
echo "regex OK"
CHECK
/bin/bash /tmp/check-regex.sh
```
Expected: `regex OK`. A false positive here corrupts both arms of two cases
and can file a spurious REGRESSION — the verdict this plan says to escalate.

- [ ] **Step 3: Verify one case loads before spending on all 16**

Run:
```bash
/bin/bash .github/scripts/run-evals.sh --plugin commit-commands-jj \
  --case 'cmd-describe' --runs 1 --gate report
```
Expected: a verdict row. If it aborts with exit 7, the grant is wrong. If the
case fails schema validation, the offender is almost certainly `weight: 0` —
do **not** revert it to a scored grader (that manufactures the delta from
plugin existence); stop and re-plan the precondition mechanism, because per
the spec, without a non-scored "did not exercise" distinction Part A does not
ship.

Then verify the precondition is *recorded* where Task 7 will read it. The
runner prints the result-JSON path on stderr; run against it:

```bash
jq -r '.cases[] | [.name,
    (([.runs[]?.graders[]? | select(.name=="invoked-command")] | length) > 0
     and ([.runs[]?.graders[]? | select(.name=="invoked-command") | .passed] | all)),
    ([.runs_without[]?.graders[]? | select(.name=="invoked-command") | .passed] | any)
  ] | @tsv' <result JSON path from stderr>
```

Expected: `cmd-describe	true	false`. Column 2 false means the model never
invoked the command — the `SlashCommand` tool name is wrong for this harness;
switch the grader to `tool: Skill` and re-run before proceeding. Column 3
true means the precondition also fires in the arm where the command cannot
exist — the grader is not measuring what it claims; stop and investigate.
(The `length > 0` guard matters: `all` over an empty array is vacuously true,
so a missing grader would otherwise read as "exercised". Verified against a
real aggregate-result.json.) Do not generate spend on 16 cases until one is
known good.

- [ ] **Step 4: Bump the version**

In `plugins/commit-commands-jj/.claude-plugin/plugin.json`, change `"version": "0.3.0"` to `"version": "0.4.0"`.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(evals): 16 command triage cases

Each prompt contains the literal slash-command invocation, because
commands are user-invoked and the model never reaches for one unprompted
(measured: 0 Skill / 0 SlashCommand calls on task-phrased prompts).

The invoked-command grader is a validity precondition at weight 0:
without it, 'did not exercise the command' is indistinguishable from
'adds nothing'; scored, it would manufacture a delta from plugin
existence, since the command cannot exist in the without arm."
jj new
```

---

### Task 7: Run the sweep and write the triage

**Files:**
- Create: `docs/eval-triage-2026-07.md`

**Interfaces:**
- Consumes: the 16 cases from Task 6.
- Produces: the triage table — a map of where each command's prose measurably shapes behaviour, informing tranche-2 effort. Not a prune list. Tranche 1's primary deliverable.

- [ ] **Step 1: Run the full sweep**

Run:
```bash
/bin/bash .github/scripts/run-evals.sh --plugin commit-commands-jj \
  --case 'cmd-*' --runs 3 --gate report --max-cost-usd 15 \
  | tee /tmp/triage.tsv
```
Expected: 16 TSV rows, ~$7, ~10 minutes. stdout is pure TSV (the runner
redirects the CLI's summary table to stderr), so the tee'd file is clean.
The runner also prints `result JSON: <path>` on stderr — **record that path**;
Step 3's exercised column is computed from it. If the run aborts with exit 6,
the cost ceiling was hit — raise `--max-cost-usd` and re-run rather than
trusting partial deltas.

- [ ] **Step 2: Re-run every zero-gap case at higher runs**

A `NO_GAP` at `runs: 3` may still be sampling noise. For each such case:

```bash
/bin/bash .github/scripts/run-evals.sh --plugin commit-commands-jj \
  --case 'cmd-<name>' --runs 5 --gate report
```
Only a result stable across both runs reaches the write-up.

- [ ] **Step 3: Write the triage document**

Create `docs/eval-triage-2026-07.md` with: a table of `command | exercised | with | without | delta | pass_rate | verdict`; a paragraph per command classifying it as *shapes behaviour* (rewards careful tranche-2 cases), *thin wrapper* (model handles it unaided), or *not exercised* (the `invoked-command` precondition failed — excluded from the reading entirely).

Compute the `exercised` column from the sweep's result JSON (the path the
runner printed on stderr). The TSV cannot carry it: the precondition is
weight 0 and invisible to scores **by design** — scored, it would
manufacture the delta, because the command cannot exist in the without arm:

```bash
jq -r '.cases[] | [.name,
    (([.runs[]?.graders[]? | select(.name=="invoked-command")] | length) > 0
     and ([.runs[]?.graders[]? | select(.name=="invoked-command") | .passed] | all)),
    ([.runs_without[]?.graders[]? | select(.name=="invoked-command") | .passed] | any)
  ] | @tsv' <result JSON>
```

Column 2 is "every with-arm run invoked the command"; `false` means NOT
EXERCISED — exclude that row's delta from the reading entirely, whatever the
verdict column says. Column 3 must be `false` for every case (the command
cannot exist in the without arm); a `true` there means the precondition is
not measuring what it claims — stop and investigate before writing a single
verdict.

**Frame this as a map, not a prune list.** This repo is a jj-native port of `anthropics/claude-plugins-official`; the command set mirrors upstream, and parity is a reason to keep a command a model could limp through without. The document must **not** recommend removing any command — a low delta means "the prose adds little measurable behaviour here", which is information about where tranche-2 test effort belongs, not grounds for deletion. State this explicitly so a future reader does not mistake the table for a hit list.

State the method and its limits plainly: 3 runs per arm, deltas are point estimates, and this is a screen rather than a verdict.

- [ ] **Step 4: File findings**

For each defect the sweep exposes, run `gh issue create` with a title naming the command and a body containing the failing prompt and the measured scores. For a `REGRESSION` verdict — the plugin making the model worse — file immediately and label it as the highest-value finding available.

- [ ] **Step 5: Commit**

```bash
jj describe -m "docs: command triage results (#79 tranche 1)

Measured ablation deltas for all 16 commit-commands-jj commands.
Screen, not verdict: 3 runs per arm, zero-gap cases re-run at 5."
jj new
```

---

### Task 8: Documentation and final verification

**Files:**
- Modify: `plugins/commit-commands-jj/README.md`
- Modify: `README.md`
- Modify: `plugins/commit-commands-jj/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: everything above.
- Produces: the documented runner, and the combined-result gate.

- [ ] **Step 1: Document the runner**

Add an `## Evals` section to the root `README.md` covering: what the suite is for; that it is **manual, not CI-gated**, and why (early-access flag, model spend, no macOS entitlement guarantee); the exact command to run it; that the runner sets `CLAUDE_CODE_WALNUT_SPIRE=1` (the early-access unlock as measured on 2.1.216; on 2.1.220 `--help` no longer requires it, and setting it stays harmless either way); and the verdict taxonomy with the note that **BROKEN means a missing tool grant, never "no gap"**.

- [ ] **Step 2: Add the attribution note**

In the same section, add one line: `Failure taxonomy informed by netresearch/jujutsu-workflow-skill (MIT AND CC-BY-SA-4.0); cases independently authored.`

- [ ] **Step 3: Bump the version**

In `plugins/commit-commands-jj/.claude-plugin/plugin.json`, change `"version": "0.4.0"` to `"version": "0.5.0"`.

- [ ] **Step 4: Run the ENTIRE repo test suite**

Not just this feature's suite. Per `project_kaisen_lessons`, per-task review never covers the combined result:

```bash
FAILED=0
for t in $(find plugins .github -path '*/tests/test-*.sh'); do
  printf '=== %s ===\n' "$t"
  /bin/bash "$t" || { printf 'SUITE FAILED: %s\n' "$t"; FAILED=$((FAILED+1)); }
done
printf '%d suite(s) failed\n' "$FAILED"
test "$FAILED" -eq 0
```
Expected: every suite reports `0 failed`, then `0 suite(s) failed`, and the
block itself exits 0. The counter is load-bearing: a bare `|| printf` loop
always exits 0, turning the combined-result gate — the reason this step
exists (#94) — into an eyeball check. A stale count or a newly-broken suite
is a blocker.

- [ ] **Step 5: Verify the version-bump lint**

Run:
```bash
BASE=$(mktemp -d)
jj --ignore-working-copy file list -r 'trunk()' 'glob:plugins/*/.claude-plugin/plugin.json' \
  | while read -r p; do
      mkdir -p "$BASE/$(dirname "$p")"
      jj --ignore-working-copy file show -r 'trunk()' "$p" > "$BASE/$p"
    done
CHANGED_FILES=$(jj --ignore-working-copy diff --from 'trunk()' --name-only) \
  BASE_DIR="$BASE" /bin/bash .github/scripts/require-version-bump.sh
```
Expected: exit 0 — `commit-commands-jj` bumped from `0.1.1`. Do **not** pass
`BASE_DIR=.`; it compares the head manifest against itself and fails always.

- [ ] **Step 6: File the follow-ups**

Task 5 Step 2 gives `commit-commands-jj` its first `tests/` file (the #45
gating test), so the layer-2 gap is now *narrowed*, not open. File the residual:

```bash
gh issue create --title "commit-commands-jj layer-2 coverage is thin (one hook test)" \
  --body "Eval work for #79 added tests/test-block-raw-git-gating.sh, but the 16 commands and the git-internals hook branch still have no deterministic shell tests. Layer 1 (evals) cannot catch a command citing a jj flag that no longer exists; layer 2 can."

gh issue create --title "Wire evals into CI if plugin eval reaches GA" \
  --body "Evals are manual per docs/specs/2026-07-20-eval-suite-design.md: they need CLAUDE_CODE_WALNUT_SPIRE, a model, and per-run spend. Revisit if the feature ships GA."
```

- [ ] **Step 7: Commit**

```bash
jj describe -m "docs(evals): document the runner and verdict taxonomy

Manual by design — early-access flag, model spend, no CI entitlement.
Full repo suite run in @ as the combined-result gate."
jj new
```

- [ ] **Step 8: Final review pass (user-triggered)**

After all tasks land and before `/finish`, the operator runs `/code-review
xhigh` over the branch as an independent final pass. This is billed and
user-invoked — the executing agent does not launch it. Address any findings it
surfaces before merging.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: verdict taxonomy → Task 2; the seven traps → Tasks 2–4 (`--allow-tools` guard in 3, null tripwire and `.partial` in 2, `--output-dir` assertion in 3); result-JSON paths → Task 2 fixtures; runner location and bash 3.2 → Tasks 1–3; Part A → Tasks 6–7; Part B → Tasks 4–5; two-layer framing → Task 8's follow-up issue; DoD items 1–9 → Tasks 1–3, 2, 5, 4, 7, 7, 4/5/6/8, 4, 8.

**Known gaps carried deliberately:**

1. **`SlashCommand` as a grader tool name is unverified.** It validates schema-wise, but whether it fires for a plugin command was never measured. Task 6 Step 3 gates all 16 cases behind one cheap probe for exactly this reason. The same probe now also gates `weight: 0` (schema acceptance was never measured either) and confirms the precondition is recorded in `runs[].graders[]`, which the exercised column depends on.
2. **The `hook-allows-jj-git-and-gh` case may return `NO_GAP`.** Task 5 Step 4 names the condition and routes it to the layer-2 suite rather than keeping a case that cannot discriminate.

**Corrections applied after adversarial review** (the plan's first draft was
wrong about each of these, all reproduced by running the code):

- `--threshold` defaults to 1.0, so the CLI exits 1 on any sub-1.00 case and `set -e` killed the runner **before `classify` ever ran** — the delta gate was unreachable, and every test passed because they all called `--classify` directly. Fixed with `--threshold 0` plus explicit rc capture, and a live-path stub test so it can never regress invisibly.
- `--max-cost-usd` breach is CLI **exit 2**, not exit 6; the `.partial` tripwire was equally unreachable.
- A result with zero cases gated **green**. Now exits 3.
- The tool-grant guard was blind to **block-style YAML** — the layout `eval init` scaffolds, i.e. exactly the case it exists to catch.
- `BASE_DIR=.` makes `require-version-bump.sh` compare a file to itself and fail unconditionally; both verification steps now materialise a real base tree from `trunk()`.
- `evals/results/` does **not** match at any depth — gitignore anchors mid-string-slash patterns to their own directory. Now `**/evals/results/`.
- The #45 pass-through case was structurally incapable of discriminating; it is now a layer-2 shell test.

**Corrections applied after the third (code-running) review, 2026-07-25** —
which transcribed Tasks 1–3 verbatim, ran the suite at every boundary under
`/bin/bash` 3.2.57, and spent one live ablation run ($0.12) on CLI 2.1.220:

- **Part A's `invoked-command` precondition was a scored grader (weight 1),
  contradicting the spec's "not a scored grader".** The command cannot exist
  in the without arm, so the grader fails there mechanically — manufacturing
  Δ ≥ +0.5 for every exercised command and filing unexercised ones as
  `NO_GAP`, with no "did not exercise" outcome anywhere in the pipeline. Now
  weight 0, gated by the Task 6 probe, with Task 7 computing an `exercised`
  column from `runs[].graders[]` (fields verified present on a live run).
- **The `no-raw-git` regex `(^|[^a-z])git (...)` matched `jj git push`** —
  the exact workflow `/commit-push-pr` and `/finish` document — and quoted
  substrings (`jj describe -m "add git log parser"`). Now command-position
  anchored (`(^ *|[;&|] *)git (...)`) and verified offline against both a
  must-not-match and a must-match list.
- **The null-delta tripwire was type-blind: a string `"0.0"` delta classified
  `DISCRIMINATING` and gated green** (jq sorts strings above every number, so
  every comparison is false). The tripwire now keys on
  `(.delta | type) != "number"`, with a `stringdelta.json` fixture and test.
- **The real CLI prints its summary table to stdout** (observed live), so
  runner stdout was not pure TSV — and the purity test passed only because
  the stub was silent. The CLI's stdout is now redirected to stderr, the stub
  prints table noise so the test can actually fail, and the runner prints the
  result-JSON path on stderr for Task 7.
- **Both expected test counts were wrong** (claimed 18/31; the verbatim code
  produced 17/29). Recounted after these amendments and verified by
  execution: 18 (3 + 15) and 30 (18 + 12).
- **Four assertions passed vacuously before their implementation existed**,
  despite the fail-first constraint: `both-arms-zero is never NO_GAP` (empty
  ≠ NO_GAP), `unknown --gate aborts` (the unknown-argument arm also exits
  64), `output-dir stays outside plugins/` and `stdout is pure TSV` (bare
  not-matches on empty output). All four now anchor on positive evidence —
  non-empty verdict, the gate-validation message, flag presence, and the TSV
  row — and were verified to FAIL against a Task-1-only runner and pass
  against the full one. The corollary is now a Global Constraint.
- **The early-access claim went stale**: on CLI 2.1.220, `plugin eval --help`
  exits 0 with `CLAUDE_CODE_WALNUT_SPIRE` unset (measured with the variable
  explicitly removed from the environment). The runner still sets it —
  harmless — but no logic may treat "exits 1 without the var" as gate
  detection, and the README wording now reflects the version drift.
- **Task 8's full-suite loop swallowed failures** — `|| printf` made the
  combined-result gate exit 0 even with a failing suite, reducing the #94
  lesson to an eyeball check. The loop now counts failures and ends with
  `test "$FAILED" -eq 0`; verified to exit 1 with a planted failing suite
  and 0 when all pass.

**Type consistency.** Verdict strings are identical across Task 2's implementation, its tests, and Tasks 5–7's usage: `DISCRIMINATING`, `PARTIAL`, `NO_GAP`, `REGRESSION`, `BROKEN`. There is no `ERROR_NULL_DELTA` verdict string — schema drift exits 5 with a diagnostic rather than emitting a row, and the earlier claim that it appeared in the implementation was false. Exit codes: 3 zero-match/zero-cases, 4 gate failure, 5 delta-type tripwire (null or non-numeric), 6 partial run, 7 tool grant, 64 bad argument or bad `--gate`, 65 missing or malformed file.
