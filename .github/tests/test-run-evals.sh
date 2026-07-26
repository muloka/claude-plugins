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
