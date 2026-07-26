#!/usr/bin/env bash
# Run plugin eval cases with ablation and gate on the delta.
# bash 3.2-safe: no globstar, no associative arrays.
set -euo pipefail

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
