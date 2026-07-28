#!/usr/bin/env bash
set -euo pipefail
HOOK="$(cd "$(dirname "$0")/../scripts" && pwd)/block-raw-git.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# Payloads are built with `jq --arg`, never printf interpolation. A command
# containing a double quote cannot be interpolated into JSON: the payload is
# malformed, the hook's `jq -r` yields an empty command, and the case then
# passes because there was nothing to block — which for an "allows …" assertion
# is indistinguishable from success. project-setup-jj's suite was migrated for
# this reason; leaving this one on printf would have reintroduced the hazard the
# moment a case like `eval "git reset --hard origin/main"` was added below.
payload() { jq -nc --arg c "$1" --arg d "$JJ_DIR" '{cwd:$d, tool_input:{command:$c}}'; }

# Inside a jj repo: raw git is denied.
JJ_DIR=$(mktemp -d); mkdir -p "$JJ_DIR/.jj"
out=$(payload 'git status' | /bin/bash "$HOOK")
if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
  ok "denies raw git inside a jj repo"
else
  bad "denies raw git inside a jj repo (got: $out)"
fi

# These run against THIS plugin's copy of the hook. The drift guard in
# project-setup-jj proves the three copies are byte-identical; only this proves
# the shipped bytes behave, which byte-identity alone would not — a sha256 guard
# is equally satisfied by three stale copies.
#
# Entries 1-4 are #101: the `jj git …` exemption used to be evaluated over the
# whole command string, so one jj-git token anywhere exempted every other clause
# and `jj git fetch && git reset --hard origin/main` came back ALLOWED.
#
# Entries 5-7 are #105: one representative per family of commands that put git
# at a real command position without a `; & |` before it. The full corpus lives
# in project-setup-jj's suite against the canonical copy.
for denied in \
  'jj git fetch && git reset --hard origin/main' \
  'git status; jj git fetch' \
  'jj git fetch;git status' \
  $'jj git fetch\ngit reset --hard origin/main' \
  'echo $(git status)' \
  '(git status)' \
  'if git diff --quiet; then echo clean; fi' \
  'git commit -m "wip"'
do
  out=$(payload "$denied" | /bin/bash "$HOOK")
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    ok "denies raw git in a compound command: $denied"
  else
    bad "denies raw git in a compound command: $denied (got: $out)"
  fi
done

# The internals branch is the hook's only code path with no other coverage.
# The raw-git branch returns first for any command carrying a bare `git `
# token, which shadows BOTH commands the internals regex names -- `git config`
# and `git rev-parse` are answered by the raw-git message, never this one. Only
# `.git/` path access reaches here. Anchor on the internals message itself:
# asserting merely "something was denied" would pass against the raw-git branch
# and prove nothing, which is the entire point of this assertion.
out=$(payload 'cat .git/HEAD' | /bin/bash "$HOOK")
if printf '%s' "$out" | grep -q 'BLOCKED: Git internals'; then
  ok "denies .git/ access via the internals branch"
else
  bad "denies .git/ access via the internals branch (got: $out)"
fi

# Outside a jj repo: passes through silently (#45). Anchor in a NON-jj temp
# dir — the dev checkout is itself a jj repo, so a relative cwd would walk up
# into the real .jj and invert this test.
PLAIN=$(mktemp -d)
out=$(jq -nc --arg d "$PLAIN" '{cwd:$d, tool_input:{command:"git status"}}' | /bin/bash "$HOOK")
if [ -z "$out" ]; then
  ok "passes git through outside a jj repo (#45)"
else
  bad "passes git through outside a jj repo (#45) (got: $out)"
fi

# The negative lookahead: `jj git ...` and `gh ...` must survive it. This
# started life as the eval case hook-allows-jj-git-and-gh, which measured
# with 1.00 / without 1.00, Δ 0.00 — NO_GAP. It asserts the *absence* of a
# deny, and the ablation's `without` arm has no hook to produce one either,
# so both arms passed and the delta could never mean anything. The hook is a
# pure stdin/stdout function, so the assertion belongs here where it is
# deterministic and free.
#
# Everything after it is a regression guard rather than a fail-first case: each
# passed before the change that prompted it and must still pass after. This hook
# is a hard wall, so a false positive costs as much as a bypass —
# /commit-push-pr and /finish both instruct `jj git push` in their own prose.
#
# Entries 3-5 are #101. Entries 6-11 are #105: widening what counts as a command
# position made `(`, `)`, backticks and `=` significant, and every one of them is
# ordinary punctuation in jj revsets and in this repo's own prose. The last four
# are the shapes that a first cut of #105 actually regressed — a PR body or
# description naming a git command in backticks, or after a parenthetical, and a
# quoted assignment value. They are here because /finish and /commit-push-pr, in
# THIS plugin, are the commands that write such text.
for allowed in "jj git remote list" "gh pr list" \
               "jj git push --bookmark feature-x" \
               "jj git fetch && jj rebase -d main" \
               "echo 'git status'" \
               "( jj git push )" \
               "jj log -r 'trunk()..@'" \
               "jj describe -m 'switch from (git status) to jj status'" \
               'gh pr create --body '"'"'stop using `git log` here'"'"'' \
               "jj describe -m 'per (#101) git is blocked'" \
               'MSG="a git b" jj describe -m x'; do
  out=$(payload "$allowed" | /bin/bash "$HOOK")
  if [ -z "$out" ]; then
    ok "allows '$allowed' inside a jj repo (lookahead)"
  else
    bad "allows '$allowed' inside a jj repo (lookahead) (got: $out)"
  fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
