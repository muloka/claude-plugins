#!/usr/bin/env bash
# Append one review to .claude/peer-review/history.jsonl, deriving the
# `concerns` array mechanically from the generalists' specialist_recommendations.
#
# WHY THIS IS A SCRIPT AND NOT AN INSTRUCTION
#
# The receiving skill used to describe the history line as a JSONL template with
# `"concerns":[{"type":"<enum>","pattern":"<description>",...}]` in it, and said
# nothing about where those values come from. The generalist schema does not even
# use those names — it returns `specialist_recommendations[]` with `concern` and
# `rationale`. So the producer had no instruction and the consumer (specialist
# emergence, which counts distinct patterns per concern type) depended on the
# field being filled.
#
# Measured on this repo's own history file: 3 of 3 entries had `concerns: []`,
# including one recording 3 important + 4 minor findings. Emergence reads that
# array, so the mechanism could never fire — it had been inert since the plugin
# shipped. Nothing caught it because peer-review-jj had no tests at all.
#
# Re-stating the mapping in prose would be the same bet that just lost: it was
# already implicitly required. Deriving it in code makes the mapping impossible
# to skip and testable, which is what tests/test-review-history.sh does.
#
# bash 3.2-safe: no globstar, no associative arrays.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: append-review-history.sh --revision <short-id> [--timestamp <unix>] [--history <path>]

Reads the aggregated review JSON on stdin:

  {
    "files_reviewed": ["a", "b"],
    "findings": [ { "severity": "important", ... } ],
    "specialist_recommendations": [
      { "concern": "Security", "rationale": "...", "files": [...], "line_ranges": [...] }
    ],
    "verdict": "with_fixes"
  }

Appends one JSONL line and prints it. --timestamp exists so tests are
deterministic; omit it in real use.
USAGE
  exit 64
}

REVISION=""
TIMESTAMP=""
HISTORY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --revision)  REVISION="${2:-}"; shift 2 ;;
    --timestamp) TIMESTAMP="${2:-}"; shift 2 ;;
    --history)   HISTORY="${2:-}"; shift 2 ;;
    -h|--help)   usage ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "$REVISION" ] || { printf 'ERROR: --revision is required\n' >&2; usage; }
[ -n "$HISTORY" ] || HISTORY=".claude/peer-review/history.jsonl"
[ -n "$TIMESTAMP" ] || TIMESTAMP=$(date +%s)

case "$TIMESTAMP" in
  ''|*[!0-9]*) printf 'ERROR: --timestamp must be a unix integer, got "%s"\n' "$TIMESTAMP" >&2; exit 64 ;;
esac

input=$(cat)

# Validate BEFORE touching the history file. A malformed aggregate must not
# leave a half-written or bogus line behind — the file is append-only and read
# by the emergence check, so one bad line silently poisons every later count.
if ! printf '%s' "$input" | jq -e . >/dev/null 2>&1; then
  printf 'ERROR: stdin is not valid JSON — nothing appended.\n' >&2
  exit 65
fi

# The whole point of the file: concerns are DERIVED, never hand-written.
#   concern   -> type
#   rationale -> pattern
# `// []` on each lookup so a generalist that omits a key yields an empty array
# rather than a null that would serialise into the history and break jq readers
# downstream. -c for one line per entry, which is what JSONL means.
line=$(printf '%s' "$input" | jq -c \
  --arg rev "$REVISION" \
  --argjson ts "$TIMESTAMP" \
  '{
     timestamp: $ts,
     revision: $rev,
     files_reviewed: (.files_reviewed // []),
     findings_count: {
       critical:  [(.findings // [])[] | select(.severity == "critical")]  | length,
       important: [(.findings // [])[] | select(.severity == "important")] | length,
       minor:     [(.findings // [])[] | select(.severity == "minor")]     | length
     },
     concerns: [
       (.specialist_recommendations // [])[]
       | {
           type:        (.concern   // "Other"),
           pattern:     (.rationale // ""),
           files:       (.files // []),
           line_ranges: (.line_ranges // [])
         }
     ],
     verdict: (.verdict // "unknown")
   }')

mkdir -p "$(dirname "$HISTORY")"
# tee -a, not Write: the file is an append-only log. Overwriting it destroys the
# history that specialist emergence is counted from.
printf '%s\n' "$line" | tee -a "$HISTORY" >/dev/null
printf '%s\n' "$line"
