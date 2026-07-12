#!/usr/bin/env bash
# Tests for fan-flames-artifacts and fan-flames-task-brief.
# Runs in a throwaway jj repo under mktemp; requires jj on PATH.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
PASS=0
FAIL=0

check() { # check DESCRIPTION COMMAND...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"; PASS=$((PASS+1))
  else
    echo "FAIL: $desc"; FAIL=$((FAIL+1))
  fi
}

check_fails() { # check_fails DESCRIPTION EXPECTED_EXIT COMMAND...
  local desc=$1 expected=$2; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $desc"; PASS=$((PASS+1))
  else
    echo "FAIL: $desc (exit $actual, expected $expected)"; FAIL=$((FAIL+1))
  fi
}

tmp=$(mktemp -d)
repo="$tmp/fan-flames-test-$$"
trap 'rm -rf "$tmp" "/tmp/jj-workspaces/$(basename "$repo")"' EXIT

# Fixture: a jj repo (uniquely named so its /tmp artifacts dir cannot collide
# with a real repo's) and a plan file with three tasks and a decoy heading
# inside a code fence.
mkdir -p "$repo"
(cd "$repo" && jj git init >/dev/null 2>&1)
cat > "$repo/plan.md" <<'EOF'
# Example Plan

## Overview

Intro text that belongs to no task.

### Task 1: First thing

**Files:** `a.ts`

- [ ] Step 1: do the first thing

### Task 2: Second thing

**Files:** `b.ts`

Body of task two, line one.

```markdown
### Task 9: decoy heading inside a code fence
this line must not terminate or start a task
```

Body of task two, line two (after the fence).

### Task 3: Third thing

**Files:** `c.ts`
EOF

cd "$repo"

# --- fan-flames-artifacts ---
dir=$("$SCRIPTS/fan-flames-artifacts")
check "artifacts prints a path under /tmp/jj-workspaces" \
  test "${dir#/tmp/jj-workspaces/}" != "$dir"
check "artifacts dir exists" test -d "$dir"
check "artifacts path ends in /artifacts" \
  test "$(basename "$dir")" = "artifacts"
check "artifacts is idempotent" \
  test "$("$SCRIPTS/fan-flames-artifacts")" = "$dir"

# --- fan-flames-task-brief ---
out=$("$SCRIPTS/fan-flames-task-brief" plan.md 2)
brief="$dir/task-2-brief.md"
check "brief reports the file it wrote" \
  test "${out#wrote $brief:}" != "$out"
check "brief file exists" test -f "$brief"
check "brief contains its own heading" grep -q '^### Task 2: Second thing' "$brief"
check "brief contains post-fence body" grep -q 'line two (after the fence)' "$brief"
check "brief keeps the fenced decoy verbatim" grep -q 'Task 9: decoy' "$brief"
check_fails "brief excludes Task 1" 1 grep -q 'First thing' "$brief"
check_fails "brief excludes Task 3" 1 grep -q 'Third thing' "$brief"

"$SCRIPTS/fan-flames-task-brief" plan.md 3 "$tmp/custom-out.md" >/dev/null
check "explicit OUTFILE honored" grep -q 'Third thing' "$tmp/custom-out.md"

check_fails "missing task exits 3" 3 "$SCRIPTS/fan-flames-task-brief" plan.md 42
check_fails "missing plan exits 2" 2 "$SCRIPTS/fan-flames-task-brief" nope.md 1
check_fails "bad usage exits 2" 2 "$SCRIPTS/fan-flames-task-brief" plan.md

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
