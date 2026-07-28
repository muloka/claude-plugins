#!/usr/bin/env bash
# Every plugin hook command must QUOTE its ${CLAUDE_PLUGIN_ROOT} expansion.
#
# Claude Code runs a hook `command` through a shell. An unquoted
#   ${CLAUDE_PLUGIN_ROOT}/scripts/block-raw-git.sh
# word-splits the moment the plugin root contains a space — and plugin roots are
# not ours to choose: they live under the user's home, the marketplace cache, or
# wherever the user cloned the repo ("~/My Projects/...", "~/Library/Mobile
# Documents/..."). The shell then tries to execute the first word and passes the
# rest as arguments, so the hook never launches.
#
# A hook that fails to launch is SILENT. For block-raw-git.sh that means the
# raw-git wall simply stops firing: no error surfaces to the user, and every
# `git` command the plugin exists to block sails through. That is the worst
# possible failure mode for a security hook — it fails open, quietly, on a
# machine whose path the maintainer never sees.
#
# The fix is the form official Anthropic plugins ship: the JSON value carries
# literal double quotes around the expansion, e.g.
#   "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/block-raw-git.sh\""
#
# Scope: plugins/*/.claude-plugin/plugin.json (hook config inline in the
# manifest) and plugins/*/hooks/hooks.json (the separate-file form documented in
# the plugins reference). No plugin uses the latter today; it is swept anyway so
# a future one is covered the day it lands rather than the day it breaks.
#
# Usage: test-plugin-hook-commands.sh [ROOT]
#   ROOT defaults to the repo root. It is overridable so this guard can be
#   pointed at a scratch tree to prove it actually fails on an unquoted command.
# bash 3.2-safe: no globstar, no associative arrays.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

cd "$ROOT"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# Both hook-carrying file shapes. `find` rather than a bash glob: a glob that
# matches nothing expands to its own literal text under bash 3.2 defaults.
files=$(find plugins \( -path '*/.claude-plugin/plugin.json' -o -path '*/hooks/hooks.json' \) \
  -type f 2>/dev/null | sort)

if [ -z "$files" ]; then
  bad "no plugin manifests or hooks.json files found under $ROOT — nothing was checked"
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  test "$FAIL" -eq 0
fi

# Extract every hook command, shape-agnostically: any object carrying
# type=="command" with a string .command, wherever it sits. This survives both
# the inline-manifest shape and the hooks.json shape (and any future nesting)
# without a hand-maintained path per file.
extract_commands() {
  jq -r '[.. | objects | select(.type? == "command" and (.command? | type == "string")) | .command] | .[]' "$1"
}

total_cmds=0
for f in $files; do
  jq empty "$f" >/dev/null 2>&1 || { bad "$f: not valid JSON"; continue; }
  cmds=$(extract_commands "$f" || true)
  [ -n "$cmds" ] || continue

  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    total_cmds=$((total_cmds + 1))

    # Commands that never name the plugin root cannot word-split on it.
    n_total=$(printf '%s' "$cmd" | grep -oE '\$\{?CLAUDE_PLUGIN_ROOT\}?' | grep -c . || true)
    if [ "$n_total" -eq 0 ]; then
      ok "$f: '$cmd' does not reference CLAUDE_PLUGIN_ROOT"
      continue
    fi

    # Quoted form: the expansion opens with a double quote and the run of
    # non-quote characters after it (the rest of the path) closes with one.
    n_quoted=$(printf '%s' "$cmd" | grep -oE '"\$\{?CLAUDE_PLUGIN_ROOT\}?[^"]*"' | grep -c . || true)

    if [ "$n_total" -eq "$n_quoted" ]; then
      ok "$f: hook command quotes CLAUDE_PLUGIN_ROOT ($n_quoted/$n_total) -> $cmd"
    else
      bad "$f: hook command leaves CLAUDE_PLUGIN_ROOT UNQUOTED ($n_quoted/$n_total quoted) -> $cmd"
      printf '       a plugin root containing a space word-splits here and the hook never launches\n'
    fi
  done <<EOF
$cmds
EOF
done

# #82 shape: a sweep that finds nothing is indistinguishable from a sweep that
# passes. Hook commands are the only thing this file exists to check, so zero of
# them means the extractor broke or the manifests changed — fail loud.
if [ "$total_cmds" -gt 0 ]; then
  ok "discovery found $total_cmds hook command(s) across $(printf '%s\n' "$files" | grep -c .) file(s)"
else
  bad "discovery found ZERO hook commands — this guard is no longer guarding anything"
fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
