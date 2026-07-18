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
assert_blocked "git config (internals)"     "git config user.name x" "$JJ_DIR"
assert_blocked "git rev-parse (internals)"  "git rev-parse HEAD"    "$JJ_DIR"

echo "=== jj repo: interop seams and non-git pass through ==="
assert_passthrough "jj git push allowed"    "jj git push"           "$JJ_DIR"
assert_passthrough "gh allowed"             "gh pr list"            "$JJ_DIR"
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
