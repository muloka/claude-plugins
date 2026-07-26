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
