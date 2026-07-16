#!/usr/bin/env bash
# Tests for kaisen-artifacts and kaisen-task-brief.
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
# with a real repo's) and a plan file with three tasks and two decoy headings
# inside code fences — one in the preamble (which the preamble pass must not
# stop at) and one inside Task 2 (which the task pass must not split on).
mkdir -p "$repo"
(cd "$repo" && jj git init >/dev/null 2>&1)
cat > "$repo/plan.md" <<'EOF'
# Example Plan

## Overview

Intro text that belongs to no task.

```markdown
### Task 8: preamble decoy inside a code fence
this fenced heading must not terminate the preamble
```

Global rule: the preamble continues past the fence.

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

# --- kaisen-artifacts ---
dir=$("$SCRIPTS/kaisen-artifacts")
check "artifacts prints a path under /tmp/jj-workspaces" \
  test "${dir#/tmp/jj-workspaces/}" != "$dir"
check "artifacts dir exists" test -d "$dir"
check "artifacts path ends in /artifacts" \
  test "$(basename "$dir")" = "artifacts"
check "artifacts is idempotent" \
  test "$("$SCRIPTS/kaisen-artifacts")" = "$dir"

# --- kaisen-task-brief ---
out=$("$SCRIPTS/kaisen-task-brief" plan.md 2)
brief="$dir/task-2-brief.md"
check "brief reports the file it wrote" \
  test "${out#wrote $brief:}" != "$out"
check "brief file exists" test -f "$brief"
check "brief contains its own heading" grep -q '^### Task 2: Second thing' "$brief"
check "brief contains post-fence body" grep -q 'line two (after the fence)' "$brief"
check "brief keeps the fenced decoy verbatim" grep -q 'Task 9: decoy' "$brief"
check_fails "brief excludes Task 1" 1 grep -q 'First thing' "$brief"
check_fails "brief excludes Task 3" 1 grep -q 'Third thing' "$brief"

# --- preamble is prepended (finding #2) ---
# A plan's Global Constraints live in the preamble, and task text references
# them without repeating them. A brief without the preamble is incomplete,
# which contradicts what the dispatch prompt tells the implementer.
check "brief contains the plan preamble" \
  grep -q 'Intro text that belongs to no task' "$brief"
check "brief separates preamble from task" grep -qx -- '---' "$brief"
check "fenced Task heading does not terminate the preamble" \
  grep -q 'Global rule: the preamble continues past the fence' "$brief"

# A plan whose first line is already a task heading has no preamble, and
# must not get a stray leading separator.
cat > "$repo/plan-nopreamble.md" <<'EOF'
### Task 1: Only thing

**Files:** `z.ts`
EOF
"$SCRIPTS/kaisen-task-brief" plan-nopreamble.md 1 "$tmp/nopre.md" >/dev/null
check "no-preamble plan still yields the task" grep -q 'Only thing' "$tmp/nopre.md"
check_fails "no-preamble plan yields no separator" 1 grep -qx -- '---' "$tmp/nopre.md"

# Every plan in this repo closes its preamble with a horizontal rule before
# the first task — it is the writing-plans convention. Our own separator must
# not double it.
cat > "$repo/plan-rule.md" <<'EOF'
# Ruled Plan

## Global Constraints

- Everything must obey this.

---

### Task 1: Ruled thing

**Files:** `r.ts`
EOF
"$SCRIPTS/kaisen-task-brief" plan-rule.md 1 "$tmp/ruled.md" >/dev/null
check "preamble ending in a rule yields exactly one separator" \
  test "$(grep -cx -- '---' "$tmp/ruled.md")" = "1"
check "trailing-rule plan keeps its constraints" \
  grep -q 'Everything must obey this' "$tmp/ruled.md"

"$SCRIPTS/kaisen-task-brief" plan.md 3 "$tmp/custom-out.md" >/dev/null
check "explicit OUTFILE honored" grep -q 'Third thing' "$tmp/custom-out.md"

check_fails "missing task exits 3" 3 "$SCRIPTS/kaisen-task-brief" plan.md 42
check_fails "missing plan exits 2" 2 "$SCRIPTS/kaisen-task-brief" nope.md 1
check_fails "bad usage exits 2" 2 "$SCRIPTS/kaisen-task-brief" plan.md

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
