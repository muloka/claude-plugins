#!/usr/bin/env bash
# Run plugin eval cases with ablation and gate on the delta.
# bash 3.2-safe: no globstar, no associative arrays.
set -euo pipefail

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

# Scope the guard to what this invocation will actually run. Scanning every
# discovered case makes an unrelated plugin's Write-requiring case abort a run
# that never touches it.
SCOPED=""
for case_dir in $CASES; do
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
