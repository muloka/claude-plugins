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

# Validate the gate name HERE, at parse time, not inside classify(). Every
# argument this script gates on is known before a token is spent; validating
# after the run means a typo burns the whole budget, prints an ungated TSV, and
# then exits 64 anyway. Without the check at all, a typo falls through to
# report semantics — silently turning a strict Part B gate permissive and green.
case "$GATE" in
  strict|report) ;;
  *) printf 'ERROR: --gate must be "strict" or "report", got "%s"\n' "$GATE" >&2
     exit 64 ;;
esac

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

  # Budget breach FIRST. A run truncated before any case finished produces
  # {"partial":true,"cases":[]}, and testing zero-cases ahead of .partial
  # diagnoses that as a discovery bug (#82) — pointing the operator at a
  # nonexistent glob problem when the fix is a larger --max-cost-usd.
  if [ "$(jq -r '.partial // false' "$file")" = "true" ]; then
    printf 'ERROR: run was truncated by --max-cost-usd (.partial=true).\n' >&2
    printf 'Paid graders were skipped; deltas are not trustworthy.\n' >&2
    exit 6
  fi

  # Zero cases is never success. `.cases[]` over an empty array prints
  # nothing, bad_count is 0, and the gate exits green having measured
  # nothing at all — #82's failure mode, one level in.
  if [ "$(jq -r '.cases | length' "$file")" = "0" ]; then
    printf 'ERROR: result contains zero cases — nothing was measured (#82).\n' >&2
    exit 3
  fi

  # Tripwire: any missing OR non-numeric delta means the result schema moved.
  # null is not the only drift shape: jq sorts every string above every
  # number, so a string "0.0" delta passes every comparison, classifies
  # DISCRIMINATING, and gates green. Key on type — never let a non-number
  # reach a comparison.
  #
  # The SCORE fields are checked with the same rigour, and for a sharper
  # reason: `.score == 0 and .score_without == 0` is false when both are null,
  # so a drift confined to the score field names leaves .delta numeric, kills
  # the both-arms-zero BROKEN detector outright, and gates a run whose scores
  # are literally null as green.
  if [ "$(jq -r '[.cases[]?
                  | select((.delta          | type) != "number"
                        or (.score          | type) != "number"
                        or (.score_without  | type) != "number")] | length' "$file")" != "0" ]; then
    printf 'ERROR: a case has a null or non-numeric delta/score — result schema drift.\n' >&2
    printf 'Expected flat numeric .cases[].delta/.score/.score_without.\n' >&2
    printf 'Every verdict would be meaningless.\n' >&2
    exit 5
  fi

  # The 0.5 threshold is compared with a tolerance, and it is load-bearing.
  # The CLI computes .delta by floating-point subtraction, so a case scoring
  # 7/10 with and 2/10 without — a textbook shipping case exactly at the
  # documented threshold — arrives as 0.49999999999999994 and is filed PARTIAL,
  # failing CI and inviting a human to cut it. 1e-9 is orders of magnitude
  # below any delta a run of at most 50 samples per arm can produce, so it
  # absorbs IEEE754 error and nothing else.
  jq -r '
    def eps: 1e-9;
    .cases[]?
    | [ .name,
        (.score          | tostring),
        (.score_without  | tostring),
        (.delta          | tostring),
        ( if   (.score == 0 and .score_without == 0) then "BROKEN"
          elif .delta <  -eps         then "REGRESSION"
          elif .delta <   eps         then "NO_GAP"
          elif .delta <  (0.5 - eps)  then "PARTIAL"
          else                             "DISCRIMINATING"
          end )
      ] | @tsv
  ' "$file"

  # Gate. strict (Part B): only DISCRIMINATING passes.
  # report (Part A): NO_GAP and PARTIAL are findings, not failures — but
  # BROKEN and REGRESSION always fail, in both modes.
  # Same tolerance as the TSV above: a gate that disagrees with the verdict it
  # printed fails a case the table calls DISCRIMINATING.
  if [ "$GATE" = "strict" ]; then
    bad_count=$(jq -r '[.cases[]? | select((.score == 0 and .score_without == 0) or .delta < (0.5 - 1e-9))] | length' "$file")
  else
    bad_count=$(jq -r '[.cases[]? | select((.score == 0 and .score_without == 0) or .delta < -1e-9)] | length' "$file")
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

# Split the grant ONCE, into one tool per line. The CLI's --allow-tools is
# variadic (`<tools...>`), so every tool must reach it as its own argv element:
# forwarding the operator's "Bash,Write" as a single element hands the CLI one
# tool name that matches nothing, the agent is denied the tool in BOTH arms,
# and the result reads 0.00/0.00 — the exact zero-vs-zero the guard below
# exists to prevent, manufactured by the runner itself.
GRANTED=$(printf '%s' "$ALLOW_TOOLS" | tr ', ' '\n\n' | grep -v '^$' || true)

# Discover case directories. BOTH supported formats: `case.yaml` and the
# `prompt.md` + graders/ layout that `claude plugin eval init --bare` writes.
# A single-format glob would silently skip officially-scaffolded cases (#82).
discover_cases() {
  find plugins \
    \( -path '*/evals/*/case.yaml' -o -path '*/evals/*/prompt.md' \) \
    -type f 2>/dev/null | sed 's#/[^/]*$##' | sort -u
}

# `find plugins` on a missing directory fails; 2>/dev/null eats the message and
# `set -e` + pipefail then kill the assignment below at exit 1 with no output
# at all. Exit 1 is not in the documented contract, and a wrong cwd is the most
# likely way to get here — every documented invocation is relative to the repo
# root. Diagnose it, and exit with the documented code.
if [ ! -d plugins ]; then
  printf 'ERROR: no plugins/ directory in %s — run from the repo root.\n' "$PWD" >&2
  printf 'A glob matching nothing is indistinguishable from passing (#82).\n' >&2
  exit 3
fi

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

# Print a prose .md file's YAML frontmatter, and nothing else. The prose below
# it may quote `allowed_tools:` while declaring nothing.
frontmatter() {
  awk 'NR == 1 { if ($0 !~ /^---[ \t]*$/) exit; next }
       /^---[ \t]*$/ { exit }
       { print }' "$1"
}

# First top-level `name:` value on stdin. No early exit: this runs downstream
# of another process, and quitting early would SIGPIPE it into a pipefail.
first_name_key() {
  awk '/^name:[ \t]*/ {
         if (!found) {
           s = $0
           sub(/^name:[ \t]*/, "", s)
           sub(/[ \t]*#.*$/, "", s)
           v = s; found = 1
         }
       }
       END { if (found) print v }'
}

# Strip leading/trailing whitespace and, if present, one matched pair of
# surrounding quotes — preserving internal spaces exactly. The prior form
# used by case_name_of, `tr -d " \"'"`, deleted every space and quote
# ANYWHERE in the value, not just a surrounding pair: `name: my case` became
# `mycase`, so --case 'my case' (which the CLI WOULD match) scoped to
# nothing and --case 'mycase' (which the CLI would NOT match) scoped in and
# passed the guard — the disjoint-set defect this closes.
dequote() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/^"\(.*\)"$/\1/' \
      -e "s/^'\(.*\)'\$/\1/"
}

# The name the CLI will match --case against. Verified against 2.1.220: the
# glob is applied to the case's `name:` field, and a prose-layout case that
# declares none defaults to its directory basename. Scoping on the basename
# instead lets the guard's set and the CLI's set go disjoint in both
# directions — inspecting a case that will not run, and running one that was
# never inspected.
case_name_of() {
  d="$1"
  n=""
  if [ -f "$d/case.yaml" ]; then
    n=$(first_name_key < "$d/case.yaml" | dequote)
  fi
  if [ -z "$n" ] && [ -f "$d/prompt.md" ]; then
    n=$(frontmatter "$d/prompt.md" | first_name_key | dequote)
  fi
  if [ -z "$n" ]; then
    n=$(basename "$d")
  fi
  printf '%s' "$n"
}

# Every tool a case declares, one per line. Handles BOTH YAML forms and BOTH
# case layouts, because a guard that silently reads nothing is worse than no
# guard: it lets the run proceed and then reports the missing grant as "no gap".
#   - flow:  allowed_tools: [Bash, "Write", 'Edit']
#   - block: allowed_tools: / # comment / - Bash / - Write
#     (comments and blank lines do NOT end a YAML block sequence; a range that
#     stops at "the first line that is not a - item" drops every tool after the
#     first comment, and ALL of them when the comment comes first)
#   - the key is ANCHORED: an unanchored match also fires on a
#     `disallowed_tools:` companion key, and the guard then demands the very
#     tool the case exists to forbid.
extract_allowed_tools() {
  awk '
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[ \t]*(-[ \t]*)?allowed_tools[ \t]*:/ {
      inblock = 0
      ind = 0
      while (substr(line, ind + 1, 1) == " " || substr(line, ind + 1, 1) == "\t") ind++
      rest = substr(line, index(line, ":") + 1)
      sub(/^[ \t]+/, "", rest)
      if (substr(rest, 1, 1) == "[") {
        endb = index(rest, "]")
        if (endb > 0) inner = substr(rest, 2, endb - 2); else inner = substr(rest, 2)
        n = split(inner, item, ",")
        for (i = 1; i <= n; i++) print item[i]
      } else if (rest == "" || substr(rest, 1, 1) == "#") {
        inblock = 1
        blockind = ind
      }
      next
    }
    inblock == 1 {
      if (line ~ /^[ \t]*$/) next
      if (line ~ /^[ \t]*#/) next
      ind = 0
      while (substr(line, ind + 1, 1) == " " || substr(line, ind + 1, 1) == "\t") ind++
      if (line ~ /^[ \t]*-[ \t]*[^ \t]/ && ind >= blockind) {
        item0 = line
        sub(/^[ \t]*-[ \t]*/, "", item0)
        sub(/[ \t]*#.*$/, "", item0)
        print item0
      } else {
        inblock = 0
      }
    }
  ' | tr -d " \"'" | grep -v '^$' || true
}

# Both layouts. The prose layout keeps its execution keys in prompt.md
# frontmatter (the CLI's set: model, max_turns, timeout_seconds, allowed_tools,
# append_system_prompt, env), so a guard that requires case.yaml and
# `continue`s otherwise is blind to every case `eval init --bare` scaffolds —
# exactly the format discovery was widened to find.
#
# A directory holding BOTH files is legal, and there the CLI lets prompt.md
# override case.yaml while this takes the union. Deliberate: for a guard,
# over-approximating costs a pre-spend abort carrying the file and tool name,
# and under-approximating costs the whole run.
declared_tools() {
  d="$1"
  {
    if [ -f "$d/case.yaml" ]; then
      extract_allowed_tools < "$d/case.yaml"
    fi
    if [ -f "$d/prompt.md" ]; then
      frontmatter "$d/prompt.md" | extract_allowed_tools
    fi
  } | sort -u
}

# Scope the guard to what this invocation will actually run. Scanning every
# discovered case makes an unrelated plugin's Write-requiring case abort a run
# that never touches it.
#
# `while read`, never `for case_dir in $CASES`: the unquoted expansion splits
# on spaces, so a case path containing one becomes fragments, none of which is
# a case directory — the guard then inspects nothing and fails open on exactly
# the input it should reject.
SCOPED=""
while IFS= read -r case_dir; do
  [ -n "$case_dir" ] || continue
  if [ -n "$PLUGIN" ]; then
    case "$case_dir" in plugins/"$PLUGIN"/*) ;; *) continue ;; esac
  fi
  if [ -n "$CASE_GLOB" ]; then
    # shellcheck disable=SC2254
    case "$(case_name_of "$case_dir")" in $CASE_GLOB) ;; *) continue ;; esac
  fi
  SCOPED="$SCOPED$case_dir
"
done <<SCOPE_EOF
$CASES
SCOPE_EOF

# Scoped to nothing is #82 one level in: the CLI would load zero cases, the run
# would measure nothing, and a silent exit 0 here is indistinguishable from
# guarded-and-clean.
if [ -z "$SCOPED" ]; then
  printf 'ERROR: --plugin/--case selected none of the discovered cases.\n' >&2
  printf 'plugin="%s" case="%s". Nothing would be measured (#82).\n' "$PLUGIN" "$CASE_GLOB" >&2
  printf 'Note --case is globbed against the case name, not the directory.\n' >&2
  exit 3
fi

# Guard: every gated tool a case declares must appear in the grant. Without
# this, the agent cannot call the tool, BOTH arms score 0.00, and the delta
# reads 0.00 — which the gate would otherwise interpret as "measures the
# model, cut the case". That silently deletes the best cases in the suite.
while IFS= read -r case_dir; do
  [ -n "$case_dir" ] || continue
  declared=$(declared_tools "$case_dir")
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    case "$tool" in
      Bash|Write|Edit|WebFetch|mcp__*)
        # Exact match against the grant list — an unanchored grep lets
        # `--allow-tools BashOutput` satisfy a requirement for `Bash`.
        if ! printf '%s\n' "$GRANTED" | grep -qx "$tool"; then
          printf 'ERROR: %s declares gated tool "%s" but --allow-tools is "%s".\n' \
            "$case_dir" "$tool" "$ALLOW_TOOLS" >&2
          printf 'Both ablation arms would score 0.00 and read as "no gap".\n' >&2
          exit 7
        fi
        ;;
    esac
  done <<TOOL_EOF
$declared
TOOL_EOF
done <<GUARD_EOF
$SCOPED
GUARD_EOF

TARGET="plugins/${PLUGIN}"
[ -n "$PLUGIN" ] || TARGET="plugins"
OUT_DIR="${TMPDIR:-/tmp}/eval-results-$$"

# --threshold 0 is LOAD-BEARING. It defaults to 1.0, so the CLI exits 1 on any
# case scoring below 1.00 — which, under `set -e`, kills this script before
# classify() ever runs. The delta gate would be permanently unreachable, and
# every case the sweep exists to measure scores below 1.00 by definition.
set -- "$TARGET" --ablation with-without --scaffold \
  --threshold 0 \
  --output-dir "$OUT_DIR" --max-cost-usd "$MAX_COST"
[ -z "$CASE_GLOB" ] || set -- "$@" --case "$CASE_GLOB"
[ -z "$RUNS" ]      || set -- "$@" --runs "$RUNS"
[ "$KEEP_TEMP" -eq 0 ] || set -- "$@" --keep-temp

# --allow-tools goes LAST, one tool per argv element. It is variadic, so it
# consumes every following non-flag token; putting it at the end means it can
# never swallow another option's value.
if [ -n "$GRANTED" ]; then
  set -- "$@" --allow-tools
  while IFS= read -r tool; do
    [ -n "$tool" ] || continue
    set -- "$@" "$tool"
  done <<GRANT_EOF
$GRANTED
GRANT_EOF
fi

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

RESULT="$(find "$OUT_DIR" -name aggregate-result.json 2>/dev/null | head -1 || true)"

# No result file is not a crash to die on with a bare `find:` message. The CLI
# writes no output directory when it loads zero cases, and under set -e that
# killed the runner one line before classify() — exit 1, no diagnosis, and the
# `result JSON:` line below never printed.
if [ -z "$RESULT" ]; then
  printf 'ERROR: no aggregate-result.json under %s — nothing was measured.\n' "$OUT_DIR" >&2
  printf 'The CLI writes no result when it loads zero cases (#82).\n' >&2
  exit 3
fi

# Task 7 reads per-grader results (the exercised precondition) from this
# file; print the path where a human can find it.
printf 'result JSON: %s\n' "$RESULT" >&2
classify "$RESULT"
