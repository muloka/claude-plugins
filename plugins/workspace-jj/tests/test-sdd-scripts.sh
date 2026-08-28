#!/usr/bin/env bash
# Tests for sdd-artifacts and sdd-review-package — the jj-native shims for
# superpowers' subagent-driven-development scripts.
#
# Runs in a throwaway jj repo under mktemp; requires jj on PATH.
# bash 3.2-safe: no globstar, no associative arrays.
#
# The guard tests here are the point of the suite, not padding. The bug these
# scripts exist to prevent is SILENT: a stale commit id resolves, diffs, and
# produces a plausible review package built against the pre-rewrite tree. So
# every guard is asserted in BOTH directions — the hidden revision must fail
# and a live one must not — because a guard that merely rejected everything
# would pass a one-sided test while breaking every real run.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL+1)); }

check() { # check DESCRIPTION COMMAND...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

check_fails() { # check_fails DESCRIPTION EXPECTED_EXIT COMMAND...
  local desc=$1 expected=$2; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then ok "$desc"
  else bad "$desc" "exit $actual, expected $expected"; fi
}

tmp=$(mktemp -d)
repo="$tmp/sdd-test-$$"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$repo"
# Normalise to the PHYSICAL path before anything compares against it. On macOS
# /var is a symlink to /private/var, so mktemp -d hands back the unresolved
# /var/folders/... while `jj root` reports the resolved /private/var/folders/...
# — and the equality assertion below fails on a script that is behaving
# correctly. Linux has no such symlink, so this is invisible there; the macOS
# leg of CI is what caught it.
repo=$(cd "$repo" && pwd -P)
# Non-colocated on purpose: `jj git init` colocates by default since 0.43, and
# a fixture that materialises the git backing directory invites a stray mention
# of it in a later test to meet block-raw-git.sh's internals matcher. Nothing
# here needs the git side.
(cd "$repo" && jj git init --config git.colocate=false >/dev/null 2>&1)

cat > "$repo/plan.md" <<'EOF'
# Example Plan

### Task 1: First thing

### Task 2: Second thing
EOF

cd "$repo"

# Two described changes plus an empty working copy on top, so BASE..HEAD spans
# a real diff rather than an empty range.
echo "one" > f.txt
jj describe -m "task 1 work" >/dev/null 2>&1
jj new >/dev/null 2>&1
echo "two" >> f.txt
jj describe -m "task 2 work" >/dev/null 2>&1
jj new >/dev/null 2>&1

# description() is an EXACT match in jj, and descriptions carry a trailing
# newline, so the bare form matches nothing. substring: is the working spelling.
T1_CHANGE=$(jj log -r 'description(substring:"task 1 work")' --no-graph -T 'change_id.short()')
T1_COMMIT=$(jj log -r 'description(substring:"task 1 work")' --no-graph -T 'commit_id.short()')

# --- sdd-artifacts ---------------------------------------------------------

check_fails "sdd-artifacts: no arguments is exit 2" 2 "$SCRIPTS/sdd-artifacts"
check_fails "sdd-artifacts: two arguments is exit 2" 2 "$SCRIPTS/sdd-artifacts" a b
check_fails "sdd-artifacts: missing plan file is exit 2" 2 "$SCRIPTS/sdd-artifacts" nope.md

DIR=$("$SCRIPTS/sdd-artifacts" plan.md)
[ "$DIR" = "$repo/.superpowers/sdd/plan" ] \
  && ok "sdd-artifacts: prints <root>/.superpowers/sdd/<plan-basename>" \
  || bad "sdd-artifacts: path" "got $DIR"

[ -d "$DIR" ] && ok "sdd-artifacts: creates the directory" \
             || bad "sdd-artifacts: creates the directory"

[ "$(cat "$repo/.superpowers/sdd/.gitignore")" = "*" ] \
  && ok "sdd-artifacts: writes the self-ignoring ignore file" \
  || bad "sdd-artifacts: writes the self-ignoring ignore file"

# The reason that ignore file exists: jj snapshots the working copy, so without
# it every brief and package would ride into the change under review.
echo "an artifact" > "$DIR/task-1-brief.md"
# Matched with `case`, not `jj status | grep -q`. Under `set -o pipefail` that
# pipeline reports FAILURE on a match: grep -q exits the moment it matches, jj
# gets SIGPIPE, and pipefail surfaces jj's death as the pipeline's status. The
# assertion then inverts — it passes only when the snapshot is dirty, which is
# the bug this line exists to catch. Every match below is pipe-free for the
# same reason.
status=$(jj status 2>/dev/null || true)
case "$status" in
  *"no changes"*) ok "sdd-artifacts: artifacts stay out of the working-copy snapshot" ;;
  *) bad "sdd-artifacts: artifacts stay out of the working-copy snapshot" "$status" ;;
esac

# --- sdd-review-package: argument handling ---------------------------------

check_fails "review-package: too few arguments is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE"
check_fails "review-package: too many arguments is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE" @ out.diff extra
check_fails "review-package: missing plan file is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" nope.md "$T1_CHANGE" @

# --- sdd-review-package: the happy path ------------------------------------

check "review-package: change ids succeed" \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE" @

PKG=$(ls "$DIR"/review-*.diff 2>/dev/null | head -n 1)
if [ -n "$PKG" ]; then
  ok "review-package: writes a package into the artifacts directory"
else
  bad "review-package: writes a package into the artifacts directory"
fi

for section in "## Changes" "## Files changed" "## Diff"; do
  if grep -qF "$section" "$PKG" 2>/dev/null; then
    ok "review-package: package contains '$section'"
  else
    bad "review-package: package contains '$section'"
  fi
done

# Both ids recorded in the header: the change id carries identity across a
# rewrite, the commit id pins which round this package was cut from.
grep -qE '^# BASE  change [k-z]+  commit [0-9a-f]+$' "$PKG" \
  && ok "review-package: header records BASE change id and commit id" \
  || bad "review-package: header records BASE change id and commit id"

# The default filename must distinguish re-review rounds. Change ids alone
# would collide with the package a fix round is meant to be compared against.
case "$(basename "$PKG")" in
  review-*..*-*.diff) ok "review-package: default filename carries both change ids and the head commit id" ;;
  *) bad "review-package: default filename shape" "got $(basename "$PKG")" ;;
esac

# Regression: OUTFILE is read before `set --` reuses the positional parameters
# to split the resolver's output. It used to be eaten there, silently sending
# every package to the default path instead of where the caller asked.
"$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE" @ "$repo/explicit.diff" >/dev/null 2>&1
[ -f "$repo/explicit.diff" ] \
  && ok "review-package: honours an explicit OUTFILE" \
  || bad "review-package: honours an explicit OUTFILE"

# --- sdd-review-package: the guards ----------------------------------------

# A LIVE commit id is a warning, not a failure — an immutable record is a
# legitimate use, and stopping an agent mid-run over it would be wrong.
warn=$("$SCRIPTS/sdd-review-package" plan.md "$T1_COMMIT" @ 2>&1 >/dev/null || true)
case "$warn" in
  *"is a COMMIT id"*) ok "review-package: live commit id warns" ;;
  *) bad "review-package: live commit id warns" "stderr was: $warn" ;;
esac
check "review-package: live commit id still succeeds" \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_COMMIT" @

# A change id must NOT warn. Without this the warning could fire on everything
# and the assertion above would still pass.
warn=$("$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE" @ 2>&1 >/dev/null || true)
case "$warn" in
  *"is a COMMIT id"*) bad "review-package: change id does not warn" "stderr was: $warn" ;;
  *) ok "review-package: change id does not warn" ;;
esac

# The core case. Rewrite task 1 the way a review round does, then feed back the
# commit id captured before it. jj resolves it, reports it hidden, and would
# otherwise diff happily against the pre-rewrite tree.
jj describe -r 'description(substring:"task 1 work")' -m "task 1 work (review round 1)" >/dev/null 2>&1

check_fails "review-package: hidden BASE is a hard error" 2 \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_COMMIT" @
err=$("$SCRIPTS/sdd-review-package" plan.md "$T1_COMMIT" @ 2>&1 >/dev/null || true)
case "$err" in
  *"HIDDEN revision"*) ok "review-package: hidden BASE names the hazard" ;;
  *) bad "review-package: hidden BASE names the hazard" "stderr was: $err" ;;
esac
case "$err" in
  *"$T1_CHANGE"*) ok "review-package: hidden BASE hands back the change id to use instead" ;;
  *) bad "review-package: hidden BASE hands back the change id to use instead" ;;
esac

# The same change id still works after the rewrite — that is the property the
# whole shim argues for, so assert it rather than implying it.
check "review-package: the change id survives the rewrite" \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE" @

# --- sdd-review-package: revset arity --------------------------------------

check_fails "review-package: unresolvable revision is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md zzzznotarev @
check_fails "review-package: a revset naming many revisions is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md 'all()' @
check_fails "review-package: a revset naming none is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md 'none()' @

# --- sdd-review-package: BASE must be on HEAD's line of history -------------

# `## Changes` is the revset range base..head; `## Files changed` and `## Diff`
# are a tree-to-tree comparison. Those agree for an ancestral pair and disagree
# for a sibling pair — and the output never says which it gave you. Measured
# before the guard: two revisions forked off the same root produced a package
# listing one change while the diff deleted a file that change never touched.
#
# `--no-edit` is load-bearing. The first cut of this used a plain
# `jj new 'root()'`, which MOVES the working copy onto the root commit — an
# empty tree, so plan.md left the disk and every case below failed on "no such
# plan file" instead. That still exits 2, so the exit-code assertion passed for
# entirely the wrong reason; only the message assertion noticed. Creating the
# sibling off to the side keeps the working copy, and its files, where the rest
# of the suite left them.
#
# The siblings are empty on purpose: this guard is about TOPOLOGY, and an empty
# revision is no more an ancestor than a populated one.
jj new 'root()' --no-edit -m "sibling work" >/dev/null 2>&1
SIB_CHANGE=$(jj log -r 'description(substring:"sibling work")' --no-graph -T 'change_id.short()')

check_fails "review-package: a BASE that is not an ancestor of HEAD is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE" "$SIB_CHANGE"

err=$("$SCRIPTS/sdd-review-package" plan.md "$T1_CHANGE" "$SIB_CHANGE" 2>&1 >/dev/null || true)
case "$err" in
  *"is not an ancestor of HEAD"*) ok "review-package: non-ancestral BASE names the contradiction" ;;
  *) bad "review-package: non-ancestral BASE names the contradiction" "stderr was: $err" ;;
esac

# The same check catches BASE and HEAD passed the wrong way round, since a
# descendant is not an ancestor either. Without this, a reversed pair produced a
# clean-looking reverse diff.
jj new "$SIB_CHANGE" --no-edit -m "sibling child" >/dev/null 2>&1
SIB_CHILD=$(jj log -r 'description(substring:"sibling child")' --no-graph -T 'change_id.short()')

check_fails "review-package: BASE and HEAD reversed is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md "$SIB_CHILD" "$SIB_CHANGE"

# And the ancestral direction of that very pair must still succeed, so the guard
# is not just rejecting everything it is handed.
check "review-package: the same pair in ancestral order succeeds" \
  "$SCRIPTS/sdd-review-package" plan.md "$SIB_CHANGE" "$SIB_CHILD"

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
