#!/usr/bin/env bash
# Prove an installed statusline actually renders. Run BY the install path, not
# by the test suite alone.
#
# Why this exists (#88): /statusline-jj-setup copied a script, wrote config, and
# told the user to restart — without ever executing the thing it installed. The
# copy it installed was dead on Linux: `stat -f` is BSD-only, GNU prints a
# filesystem report and exits 0 instead of failing, and the resulting blob
# reached `$(( ))` where `set -u` aborted the script. 185 assertions covered the
# INSTALLER; nothing covered the INSTALLED RESULT. The gap cost a feature that
# silently never appeared — which reads as "not configured yet", not "crashed".
#
# Two renders, not one, because one render cannot see #88. The first render
# populates /tmp/statusline-claude-summary; the crash needs that file to already
# exist, so it lands on the SECOND render and every one after it. A smoke test
# that rendered once would have passed over the exact bug it exists to catch.
#
# The cache-key check covers the other half of the same bug. Where curl cannot
# reach the status API the arithmetic is never entered and both renders succeed
# — while the key silently carries a filesystem report whose free-block counts
# drift with disk usage, so the cache never validates (#63's pathology). Shape
# is the tell: two numeric mtimes.
#
# Usage: statusline-smoke.sh <path-to-statusline-script>
# Output: statusline_smoke=pass | statusline_smoke=fail:<reason>
# Exit:   0 pass, 1 fail
#
# bash 3.2-safe (macOS): no globstar, no associative arrays.

# NOT `set -e`: the whole point is to OBSERVE a failing render and report why,
# rather than inherit its exit status and die with it.
set -uo pipefail

SL="${1:-}"

fail() { printf 'statusline_smoke=fail:%s\n' "$1"; exit 1; }

[ -n "$SL" ]   || fail "no statusline path given"
[ -f "$SL" ]   || fail "not found: $SL"
[ -r "$SL" ]   || fail "not readable: $SL"

bash -n "$SL" 2>/dev/null || fail "syntax error in $SL"

# A payload with the keys the script reads. context_window is what drives the
# percent badge; the rest keep the jq lookups on their normal paths.
PAYLOAD='{"model":{"display_name":"Smoke Test"},"context_window":{"used_percentage":7},"cost":{"total_cost_usd":0}}'

CACHE_DIR=$(mktemp -d 2>/dev/null) || fail "cannot create a temp cache dir"
trap 'rm -rf "$CACHE_DIR"' EXIT

render() {
  printf '%s' "$PAYLOAD" | STATUSLINE_JJ_CACHE_DIR="$CACHE_DIR" bash "$SL" 2>"$CACHE_DIR/err"
}

out1=$(render); code1=$?
[ "$code1" -eq 0 ] || fail "first render exited $code1: $(head -1 "$CACHE_DIR/err" 2>/dev/null)"
[ -n "$out1" ]     || fail "first render produced no output"

out2=$(render); code2=$?
[ "$code2" -eq 0 ] || fail "second render exited $code2: $(head -1 "$CACHE_DIR/err" 2>/dev/null)"
[ -n "$out2" ]     || fail "second render produced no output"

# The cache is only written inside a jj repo — outside one the script renders a
# two-badge fallback and returns before the cache exists. Absent there is
# correct, so only check the key where there is one to check.
if jj root >/dev/null 2>&1; then
  cache_file=$(find "$CACHE_DIR" -type f ! -name err 2>/dev/null | head -1)
  [ -n "$cache_file" ] || fail "no cache file written inside a jj repo"
  key=$(head -1 "$cache_file")
  case "$key" in
    *[!0-9.:]*|*:*:*|"") fail "cache key is not a numeric mtime pair: $(printf '%s' "$key" | cut -c1-60)" ;;
    *:*)                 : ;;
    *)                   fail "cache key is not a numeric mtime pair: $(printf '%s' "$key" | cut -c1-60)" ;;
  esac
fi

printf 'statusline_smoke=pass\n'
