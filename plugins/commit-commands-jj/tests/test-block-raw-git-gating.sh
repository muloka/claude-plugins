#!/usr/bin/env bash
set -euo pipefail
HOOK="$(cd "$(dirname "$0")/../scripts" && pwd)/block-raw-git.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

# Inside a jj repo: raw git is denied.
JJ_DIR=$(mktemp -d); mkdir -p "$JJ_DIR/.jj"
out=$(printf '{"cwd":"%s","tool_input":{"command":"git status"}}' "$JJ_DIR" | /bin/bash "$HOOK")
if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
  ok "denies raw git inside a jj repo"
else
  bad "denies raw git inside a jj repo (got: $out)"
fi

# #101: the `jj git …` exemption used to be evaluated over the whole command
# string, so one jj-git token anywhere exempted every other clause and
# `jj git fetch && git reset --hard origin/main` came back ALLOWED. These run
# against THIS plugin's copy of the hook — the drift-guard in project-setup-jj
# proves byte-identity, this proves the shipped bytes behave.
for denied in \
  'jj git fetch && git reset --hard origin/main' \
  'git status; jj git fetch' \
  'jj git fetch;git status' \
  'jj git fetch\ngit reset --hard origin/main'
do
  out=$(printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$JJ_DIR" "$denied" | /bin/bash "$HOOK")
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
out=$(printf '{"cwd":"%s","tool_input":{"command":"cat .git/HEAD"}}' "$JJ_DIR" | /bin/bash "$HOOK")
if printf '%s' "$out" | grep -q 'BLOCKED: Git internals'; then
  ok "denies .git/ access via the internals branch"
else
  bad "denies .git/ access via the internals branch (got: $out)"
fi

# Outside a jj repo: passes through silently (#45). Anchor in a NON-jj temp
# dir — the dev checkout is itself a jj repo, so a relative cwd would walk up
# into the real .jj and invert this test.
PLAIN=$(mktemp -d)
out=$(printf '{"cwd":"%s","tool_input":{"command":"git status"}}' "$PLAIN" | /bin/bash "$HOOK")
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
# The trailing three are #101 regression guards rather than fail-first cases:
# they passed before the per-clause split and must still pass after it. This
# hook is a hard wall, so a false positive costs as much as a bypass —
# /commit-push-pr and /finish both instruct `jj git push` in their own prose.
for allowed in "jj git remote list" "gh pr list" \
               "jj git push --bookmark feature-x" \
               "jj git fetch && jj rebase -d main" \
               "echo 'git status'"; do
  out=$(printf '{"cwd":"%s","tool_input":{"command":"%s"}}' "$JJ_DIR" "$allowed" | /bin/bash "$HOOK")
  if [ -z "$out" ]; then
    ok "allows '$allowed' inside a jj repo (lookahead)"
  else
    bad "allows '$allowed' inside a jj repo (lookahead) (got: $out)"
  fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
