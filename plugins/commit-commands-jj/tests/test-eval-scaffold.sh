#!/usr/bin/env bash
# The eval scaffolds' anti-hang hardening must reach the AGENT, not just the
# scaffold process.
#
# `claude plugin eval` spawns scaffold.sh with a fixed environment whitelist
# (PATH, HOME, USERPROFILE, TMPDIR, TERM, USER_TYPE, NODE_ENV) and then runs
# the agent turn in a SEPARATE process. Anything the scaffold `export`s dies
# with the scaffold, so `export JJ_CONFIG=...` configures nothing the turn can
# see: an interactive `jj describe` opens the real editor and blocks until
# timeout_seconds, burning the run and the money for it.
#
# What both processes DO share is HOME — the CLI points it at a throwaway
# sandbox home for the scaffold, and gives the agent the same HOME plus
# XDG_CONFIG_HOME=$HOME/.config. So jj's user config inside that sandbox home
# is the one channel that actually crosses the process boundary. This suite
# reproduces both environments exactly and asserts the crossing.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jj >/dev/null 2>&1; then
  printf 'FAIL - jj must be installed to verify the scaffolds\n'
  printf '0 passed, 1 failed\n'
  exit 1
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

for case_name in hook-blocks-raw-git hook-blocks-git-internals; do
  scaffold="$PLUGIN_DIR/evals/$case_name/scaffold.sh"
  sandbox=$(mktemp -d "$TMPROOT/sb.XXXXXX")
  mkdir -p "$sandbox/home" "$sandbox/cwd"

  # Exactly the env the CLI hands the scaffold — no more. `env -i` is the
  # point: inheriting this shell's HOME would let the assertions below pass
  # against the developer's own ~/.config/jj.
  set +e
  err=$(cd "$sandbox/cwd" && env -i \
    PATH="$PATH" HOME="$sandbox/home" USERPROFILE="$sandbox/home" \
    TMPDIR="${TMPDIR:-/tmp}" TERM=dumb USER_TYPE=external NODE_ENV=production \
    /bin/bash "$scaffold" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    ok "$case_name: scaffold runs under the CLI's env whitelist"
  else
    bad "$case_name: scaffold runs under the CLI's env whitelist (rc=$rc: ${err:-<empty>})"
  fi

  # ...and exactly the env the CLI hands the agent turn.
  agent_jj() {
    (cd "$sandbox/cwd" && env -i \
      PATH="$PATH" HOME="$sandbox/home" USERPROFILE="$sandbox/home" \
      XDG_CONFIG_HOME="$sandbox/home/.config" TMPDIR="${TMPDIR:-/tmp}" TERM=dumb \
      jj "$@")
  }

  editor=$(agent_jj config get ui.editor 2>/dev/null || printf '<unset>')
  if [ "$editor" = "true" ]; then
    ok "$case_name: ui.editor reaches a separate process"
  else
    bad "$case_name: ui.editor reaches a separate process (got: $editor)"
  fi

  paginate=$(agent_jj config get ui.paginate 2>/dev/null || printf '<unset>')
  if [ "$paginate" = "never" ]; then
    ok "$case_name: ui.paginate reaches a separate process"
  else
    bad "$case_name: ui.paginate reaches a separate process (got: $paginate)"
  fi

  # An identity the turn can rely on: JJ_USER/JJ_EMAIL are not on the
  # scaffold's env whitelist either, so exporting them there sets nothing.
  who=$(agent_jj config get user.name 2>/dev/null || printf '<unset>')
  if [ -n "$who" ] && [ "$who" != "<unset>" ]; then
    ok "$case_name: a jj identity reaches a separate process"
  else
    bad "$case_name: a jj identity reaches a separate process (got: $who)"
  fi

  # The payoff assertion: an interactive jj command must no-op instead of
  # blocking on an editor. Only run it once the editor is known to be `true` —
  # invoking a real editor under a dumb terminal is the hang this exists to
  # prevent, and a test suite must not reproduce it.
  if [ "$editor" = "true" ]; then
    set +e
    out=$(agent_jj describe </dev/null 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      ok "$case_name: an editor-opening jj command returns instead of hanging"
    else
      bad "$case_name: an editor-opening jj command returns instead of hanging (rc=$rc: $out)"
    fi
  else
    bad "$case_name: an editor-opening jj command returns instead of hanging (editor is $editor — not invoking it)"
  fi

  # Scaffold config must stay OUT of the work tree: the CLI diffs the sandbox
  # cwd before and after the turn, and a config directory in there shows up as
  # a file the agent supposedly created (see docs/eval-triage-2026-07.md §3).
  if [ ! -e "$sandbox/cwd/.jjconfig" ]; then
    ok "$case_name: scaffold leaves no config inside the work tree"
  else
    bad "$case_name: scaffold leaves no config inside the work tree"
  fi

  if [ -d "$sandbox/cwd/.jj" ] && [ -f "$sandbox/cwd/notes.txt" ]; then
    ok "$case_name: scaffold builds the repo the case expects"
  else
    bad "$case_name: scaffold builds the repo the case expects"
  fi

  # Colocation is load-bearing for the internals case and only for it: that
  # prompt reads the git directory at the work-tree root, and a plain
  # `jj git init` keeps the backend inside .jj/ where there is nothing to read.
  # Lose the --colocate flag and the ablation's without-arm starts failing on a
  # missing file — still scoring 0, so the delta stays +1.00 and the regression
  # is invisible in the numbers (#103).
  if [ "$case_name" = "hook-blocks-git-internals" ]; then
    if [ -f "$sandbox/cwd/.git/HEAD" ]; then
      ok "$case_name: scaffold colocates, so the git dir is readable"
    else
      bad "$case_name: scaffold colocates, so the git dir is readable"
    fi
  fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
