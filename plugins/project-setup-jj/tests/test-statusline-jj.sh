#!/usr/bin/env bash
set -euo pipefail

# Test the jj statusline script for regressions
# Runs against a temporary jj repo to verify:
#   1. Script exits 0 and produces output (non-crash)
#   2. Trunk label reflects bookmark-ahead-of-origin state

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SL="$SCRIPT_DIR/../scripts/statusline-jj.sh"
STDIN='{"model":{"display_name":"Test Model"},"context_window":{"used_percentage":42}}'

pass=0
fail=0

assert_ok() {
  local test_name="$1"
  local output="$2"
  local exit_code="$3"
  if [ "$exit_code" -eq 0 ] && [ -n "$output" ]; then
    echo "  PASS: $test_name"
    pass=$((pass + 1))
  else
    echo "  FAIL: $test_name — exit=$exit_code output_len=${#output}"
    fail=$((fail + 1))
  fi
}

assert_contains() {
  local test_name="$1"
  local output="$2"
  local pattern="$3"
  # Strip ANSI escape codes for matching
  local clean
  clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  if printf '%s' "$clean" | grep -qF "$pattern"; then
    echo "  PASS: $test_name"
    pass=$((pass + 1))
  else
    echo "  FAIL: $test_name — expected '$pattern' in: $clean"
    fail=$((fail + 1))
  fi
}

assert_not_contains() {
  local test_name="$1"
  local output="$2"
  local pattern="$3"
  local clean
  clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
  if printf '%s' "$clean" | grep -qF "$pattern"; then
    echo "  FAIL: $test_name — unexpected '$pattern' in: $clean"
    fail=$((fail + 1))
  else
    echo "  PASS: $test_name"
    pass=$((pass + 1))
  fi
}

# ── Setup: temp jj repo with a fake origin ──
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

REMOTE="$TMPDIR_ROOT/origin"
REPO="$TMPDIR_ROOT/repo"

# Create bare "remote" (git backend for jj)
git init --bare "$REMOTE" >/dev/null 2>&1

# Clone into working repo via jj
jj git clone "$REMOTE" "$REPO" >/dev/null 2>&1 || {
  # Fresh bare repo has no commits; init jj repo and add remote manually
  jj git init "$REPO" >/dev/null 2>&1
  (cd "$REPO" && jj git remote add origin "$REMOTE" 2>/dev/null || true)
}

cd "$REPO"

# Seed an initial commit and push to set up main@origin
echo "init" > file.txt
jj describe -m "initial commit" 2>/dev/null
jj new 2>/dev/null
jj bookmark set main -r @- 2>/dev/null || true
jj git push --bookmark main 2>/dev/null || true

echo ""
echo "=== Statusline Script Tests ==="

# ── Test 1: Script produces output and exits 0 ──
out=$(echo "$STDIN" | bash "$SL" 2>/dev/null) || true
code=$?
# Re-run to get accurate exit code (|| true swallows it)
echo "$STDIN" | bash "$SL" > /tmp/sl-test-out 2>/dev/null
code=$?
out=$(cat /tmp/sl-test-out)

assert_ok "script exits 0 with output" "$out" "$code"

# ── Test 2: Shows model name ──
assert_contains "displays model name" "$out" "Test Model"

# ── Test 3: Shows context percentage ──
assert_contains "displays context percent" "$out" "42%"

# ── Test 4: Shows @trunk when synced ──
assert_contains "shows @trunk when synced" "$out" "@trunk"
assert_not_contains "no asterisk when synced" "$out" "@trunk*"

# ── Test 5: After local-only commit, shows asterisk ──
echo "local change" > file2.txt
jj describe -m "local only" 2>/dev/null
jj new 2>/dev/null
jj bookmark set main -r @- 2>/dev/null || true
# Don't push — main is now ahead of main@origin

out2=$(echo "$STDIN" | bash "$SL" 2>/dev/null) || true
echo "$STDIN" | bash "$SL" > /tmp/sl-test-out2 2>/dev/null
code2=$?
out2=$(cat /tmp/sl-test-out2)

assert_ok "script exits 0 after local commit" "$out2" "$code2"
assert_contains "shows asterisk when ahead of origin" "$out2" "*"

# ── Test 6: Regression — no master bookmark doesn't crash (pipefail guard) ──
# The repo only has main, not master. If the push-detection loop doesn't
# guard against missing bookmarks, set -euo pipefail kills the script.
echo "$STDIN" | bash "$SL" > /tmp/sl-test-out3 2>/dev/null
code3=$?
out3=$(cat /tmp/sl-test-out3)
assert_ok "no crash when master bookmark missing (pipefail regression)" "$out3" "$code3"

# ── Test 7: one cache file is shared across invocations ──
# Regression: Claude Code spawns the statusline as a NEW PROCESS per redraw, so a
# $$-keyed cache filename can never match on the next run. That made the cache-hit
# branch dead code (all 11 jj queries re-ran every redraw) and leaked one /tmp file
# per redraw — ~6,000 files / 24MB had accumulated before this was caught.
CACHE_PROBE="$TMPDIR_ROOT/cache-probe"
mkdir -p "$CACHE_PROBE"

for _i in 1 2 3; do
  STATUSLINE_JJ_CACHE_DIR="$CACHE_PROBE" bash "$SL" <<<"$STDIN" >/dev/null 2>&1 || true
done

n_cache=$(find "$CACHE_PROBE" -type f | wc -l | tr -d ' ')
if [ "$n_cache" -eq 1 ]; then
  echo "  PASS: three invocations share one cache file"
  pass=$((pass + 1))
else
  echo "  FAIL: three invocations produced $n_cache cache files (expected 1)"
  fail=$((fail + 1))
fi

# ── Test 8: the cache-hit branch is actually taken ──
# Poison the cached payload while keeping the validity key intact. A genuine hit
# renders the sentinel; a miss re-queries jj and the sentinel never appears.
# Without this, test 7 alone would still pass if the cache were written but never read.
cache_file=$(find "$CACHE_PROBE" -type f | head -1)
if [ -n "$cache_file" ]; then
  _key=$(head -1 "$cache_file")
  printf '%s\n%s' "$_key" "|sentin3l|poisoned|@trunk|healthy" > "$cache_file"
  out7=$(STATUSLINE_JJ_CACHE_DIR="$CACHE_PROBE" bash "$SL" <<<"$STDIN" 2>/dev/null || true)
  assert_contains "cache-hit branch is used (sentinel rendered)" "$out7" "sentin3l"
else
  echo "  FAIL: no cache file created — cannot verify cache-hit branch"
  fail=$((fail + 1))
fi

# ── Summary ──
echo ""
total=$((pass + fail))
echo "Results: $pass/$total passed"
if [ "$fail" -gt 0 ]; then
  echo "FAILED"
  exit 1
else
  echo "ALL PASSED"
  exit 0
fi
