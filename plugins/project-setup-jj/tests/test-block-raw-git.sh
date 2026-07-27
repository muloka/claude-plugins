#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# project-setup-jj is the canonical superset copy; behaviour is tested against
# it, and the drift-guard proves the other two are byte-identical.
HOOK="$REPO_ROOT/plugins/project-setup-jj/scripts/block-raw-git.sh"

COPIES="plugins/commit-commands-jj/scripts/block-raw-git.sh
plugins/peer-review-jj/scripts/block-raw-git.sh
plugins/project-setup-jj/scripts/block-raw-git.sh"

pass=0
fail=0

# Run the hook with a command + cwd; capture stdout (hook never uses stderr).
run_hook() {
  local cmd="$1"
  local cwd="$2"
  local json='{"tool_input":{"command":"'"$cmd"'"},"tool_name":"Bash","hook_event_name":"PreToolUse","cwd":"'"$cwd"'"}'
  echo "$json" | bash "$HOOK" 2>/dev/null || true
}

assert_blocked() {
  local name="$1" cmd="$2" cwd="$3"
  local out
  out=$(run_hook "$cmd" "$cwd")
  if echo "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null | grep -q '^deny$'; then
    echo "  PASS: $name"; pass=$((pass + 1))
  else
    echo "  FAIL: $name — expected deny, got: $out"; fail=$((fail + 1))
  fi
}

assert_passthrough() {
  local name="$1" cmd="$2" cwd="$3"
  local out
  out=$(run_hook "$cmd" "$cwd")
  if [ -z "$out" ]; then
    echo "  PASS: $name"; pass=$((pass + 1))
  else
    echo "  FAIL: $name — expected pass-through (no output), got: $out"; fail=$((fail + 1))
  fi
}

# Temp repos: one jj (with a subdir), one pure-git.
JJ_DIR=$(mktemp -d); mkdir -p "$JJ_DIR/.jj" "$JJ_DIR/sub/deep"
GIT_DIR=$(mktemp -d); mkdir -p "$GIT_DIR/.git" "$GIT_DIR/src"
trap 'rm -rf "$JJ_DIR" "$GIT_DIR"' EXIT

echo "=== jj repo: raw git is blocked ==="
assert_blocked "git status at jj root"      "git status"            "$JJ_DIR"
assert_blocked "git status in jj subdir"    "git status"            "$JJ_DIR/sub/deep"
assert_blocked "git commit at jj root"      "git commit -m x"       "$JJ_DIR"
assert_blocked "git add"                    "git add -A"            "$JJ_DIR"
assert_blocked "git log"                    "git log --oneline"     "$JJ_DIR"
assert_blocked "git diff"                   "git diff"              "$JJ_DIR"
assert_blocked "git push"                   "git push origin main"  "$JJ_DIR"
assert_blocked "git reset --hard"           "git reset --hard origin/main" "$JJ_DIR"
assert_blocked "git config (internals)"     "git config user.name x" "$JJ_DIR"
assert_blocked "git rev-parse (internals)"  "git rev-parse HEAD"    "$JJ_DIR"

# #101: the jj-git exemption used to be evaluated over the WHOLE command
# string, so a single `jj git …` token anywhere exempted every other clause —
# `jj git fetch && git reset --hard origin/main` was ALLOWED even though the
# second clause is denied on its own. The exemption is now decided per clause.
# Chaining a fetch onto another command is ordinary model output, not an
# adversarial input, so every separator the shell accepts is covered here.
echo "=== jj repo: compound commands are decided per clause (#101) ==="
assert_blocked "jj-git clause then raw git (&&)"  "jj git fetch && git reset --hard origin/main" "$JJ_DIR"
assert_blocked "jj-git clause then raw git (;)"   "jj git push; git status"                      "$JJ_DIR"
assert_blocked "raw git then jj-git clause (;)"   "git status; jj git fetch"                     "$JJ_DIR"
assert_blocked "raw git then jj-git clause (||)"  "git log --oneline || jj git fetch"            "$JJ_DIR"
assert_blocked "jj-git clause piped into raw git" "jj git fetch | git log --oneline"             "$JJ_DIR"
assert_blocked "no space after ; separator"       "jj git fetch;git status"                      "$JJ_DIR"
assert_blocked "no space after && separator"      "jj git fetch&&git status"                     "$JJ_DIR"
assert_blocked "raw git in a third clause"        "echo hi && jj git fetch && git status"        "$JJ_DIR"
# Newlines are folded to ';' before analysis, so a multi-line command must
# split the same way. The \n below is a JSON escape: jq hands the hook a real
# newline.
assert_blocked "multi-line: newline is a separator" 'jj git fetch\ngit reset --hard origin/main' "$JJ_DIR"

# These are regression guards, not fail-first cases: every one of them passed
# before the #101 per-clause fix and must still pass after it. A false positive
# in this hook is as bad as a bypass — `jj git push` is instructed in the
# command prose of /commit-push-pr and /finish, so a hook that blocks it breaks
# the documented workflow of three plugins.
echo "=== jj repo: interop seams and non-git pass through ==="
assert_passthrough "jj git push allowed"    "jj git push"           "$JJ_DIR"
assert_passthrough "jj git push with bookmark" "jj git push --bookmark feature-x" "$JJ_DIR"
assert_passthrough "jj git push --change"   "jj git push --change @" "$JJ_DIR"
assert_passthrough "jj git fetch"           "jj git fetch"          "$JJ_DIR"
assert_passthrough "jj git remote list"     "jj git remote list"    "$JJ_DIR"
assert_passthrough "jj git init"            "jj git init"           "$JJ_DIR"
assert_passthrough "two jj clauses, one jj-git" "jj git fetch && jj rebase -d main" "$JJ_DIR"
assert_passthrough "jj-git clause last"     "jj log -r @ && jj git push" "$JJ_DIR"
assert_passthrough "gh allowed"             "gh pr list"            "$JJ_DIR"
assert_passthrough "gh with flags"          "gh pr create --title x --body y" "$JJ_DIR"
# Mid-clause prose is not command position: a message that merely names a git
# command must not be blocked.
assert_passthrough "git named inside a -m message" "jj describe -m 'replace git status with jj status'" "$JJ_DIR"
assert_passthrough "quoted git string echoed"      "echo 'git status'" "$JJ_DIR"
assert_passthrough "non-git command"        "ls -la"               "$JJ_DIR"

echo "=== non-jj repo: git is allowed ==="
assert_passthrough "git status in git root"   "git status"          "$GIT_DIR"
assert_passthrough "git status in git subdir" "git status"          "$GIT_DIR/src"
assert_passthrough "git commit in non-jj"     "git commit -m x"     "$GIT_DIR"
assert_passthrough "git config in non-jj"     "git config user.name x" "$GIT_DIR"

echo "=== drift-guard: all three copies are byte-identical ==="
uniq_hashes=$( (cd "$REPO_ROOT" && shasum -a 256 $COPIES) | awk '{print $1}' | sort -u | grep -c . )
if [ "$uniq_hashes" = "1" ]; then
  echo "  PASS: block-raw-git.sh copies share one sha256"; pass=$((pass + 1))
else
  echo "  FAIL: block-raw-git.sh copies have diverged:"; fail=$((fail + 1))
  (cd "$REPO_ROOT" && shasum -a 256 $COPIES)
fi

echo "=== regression: relative cwd must terminate (no infinite dirname loop) ==="
# Relative cwd values are resolved against the test process's real PWD, so
# run these from inside the non-jj $GIT_DIR — anchoring anywhere under this
# repo's own jj working copy would let the walk-up find the real .jj and
# report "blocked" instead of the pass-through these assertions check for.
_orig_pwd="$PWD"
cd "$GIT_DIR"
assert_passthrough "relative cwd terminates, passes through" "git status" "some/relative/path"
assert_passthrough "bare-dot cwd terminates, passes through" "git status" "."
cd "$_orig_pwd"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
