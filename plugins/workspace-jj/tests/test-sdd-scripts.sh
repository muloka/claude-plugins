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

# --- sdd-review-package: --evolution-diff mode ------------------------------
#
# describe-only rewrites (used above) don't touch the tree, so they can't
# exercise "## Diff showing the content the rewrite changed". Build a
# dedicated fixture where the SAME change's CONTENT changes across a
# rewrite: `jj new` (a normal child of @, not `root()` — a root-based commit
# has an EMPTY tree, and editing into one wipes plan.md et al from disk, the
# exact gotcha the sibling-fixture comment above warns about) lands us on the
# new change, so editing its file and re-describing auto-snapshots a new
# commit id for the same change id and hides the old one — a real evolution,
# not just a description edit.
jj new >/dev/null 2>&1
echo "evo before" > evo.txt
jj describe -m "evo task work" >/dev/null 2>&1
EVO_CHANGE=$(jj log -r 'description(substring:"evo task work")' --no-graph -T 'change_id.short()')
EVO_BASE=$(jj log -r 'description(substring:"evo task work")' --no-graph -T 'commit_id.short()')

echo "evo after" > evo.txt
jj describe -m "evo task work" >/dev/null 2>&1

# fixture-is-honest: EVO_BASE really is hidden, and really shares HEAD's
# (EVO_CHANGE's) change id.
hidden=$(jj log -r "$EVO_BASE" --no-graph -T 'if(hidden,"hidden","visible")')
[ "$hidden" = "hidden" ] \
  && ok "evolution-diff fixture: pre-rewrite commit is really hidden" \
  || bad "evolution-diff fixture: pre-rewrite commit is really hidden" "got $hidden"

base_change_of=$(jj log -r "$EVO_BASE" --no-graph -T 'change_id.short()')
[ "$base_change_of" = "$EVO_CHANGE" ] \
  && ok "evolution-diff fixture: pre-rewrite commit shares HEAD's change id" \
  || bad "evolution-diff fixture: pre-rewrite commit shares HEAD's change id" "got $base_change_of"

# fixture-is-honest: EVO_CHANGE and T1_CHANGE really are different changes —
# needed for the "different changes" case below.
[ "$EVO_CHANGE" != "$T1_CHANGE" ] \
  && ok "evolution-diff fixture: EVO and T1 really are different changes" \
  || bad "evolution-diff fixture: EVO and T1 really are different changes"

# fails-correctly: DEFAULT mode, hidden BASE of the SAME change as HEAD ->
# exit 2 AND stderr contains the runnable rerun command (the discoverability
# contract from #172: the error IS the documentation).
check_fails "review-package: default mode, hidden BASE of HEAD's own change is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md "$EVO_BASE" "$EVO_CHANGE"
err=$("$SCRIPTS/sdd-review-package" plan.md "$EVO_BASE" "$EVO_CHANGE" 2>&1 >/dev/null || true)
case "$err" in
  # The leading token matters (M5): the rerun command must be directly
  # invokable as printed, via `$0` — not merely mention the flag somewhere.
  *"$SCRIPTS/sdd-review-package --evolution-diff plan.md $EVO_BASE $EVO_CHANGE"*)
    ok "review-package: same-change hidden BASE hands back the runnable rerun command" ;;
  *) bad "review-package: same-change hidden BASE hands back the runnable rerun command" "stderr was: $err" ;;
esac

# fails-correctly: --evolution-diff with BASE and HEAD of DIFFERENT changes ->
# exit 2, error names both change ids. The flag declares intent, it does not
# disable the guard.
check_fails "review-package: --evolution-diff with different changes is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$EVO_BASE" "$T1_CHANGE"
err=$("$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$EVO_BASE" "$T1_CHANGE" 2>&1 >/dev/null || true)
case "$err" in
  *"$EVO_CHANGE"*"$T1_CHANGE"*) ok "review-package: --evolution-diff different changes names both change ids" ;;
  *) bad "review-package: --evolution-diff different changes names both change ids" "stderr was: $err" ;;
esac

# happy path: --evolution-diff with the hidden pre-rewrite commit as BASE and
# its evolved change as HEAD.
check "review-package: --evolution-diff succeeds for a same-change hidden BASE" \
  "$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$EVO_BASE" "$EVO_CHANGE"

EVO_PKG=$(ls "$DIR"/evolution-*.diff 2>/dev/null | head -n 1)
if [ -n "$EVO_PKG" ]; then
  ok "review-package: --evolution-diff writes a package into the artifacts directory"
else
  bad "review-package: --evolution-diff writes a package into the artifacts directory"
fi

if grep -qF "## Evolution" "$EVO_PKG" 2>/dev/null; then
  ok "review-package: --evolution-diff package contains '## Evolution'"
else
  bad "review-package: --evolution-diff package contains '## Evolution'"
fi

if grep -qF "## Changes" "$EVO_PKG" 2>/dev/null; then
  bad "review-package: --evolution-diff package does not contain '## Changes'"
else
  ok "review-package: --evolution-diff package does not contain '## Changes'"
fi

if grep -qF "$EVO_CHANGE" "$EVO_PKG" 2>/dev/null; then
  ok "review-package: --evolution-diff package's evolog names the change"
else
  bad "review-package: --evolution-diff package's evolog names the change"
fi

for section in "## Files changed" "## Diff"; do
  if grep -qF "$section" "$EVO_PKG" 2>/dev/null; then
    ok "review-package: --evolution-diff package contains '$section'"
  else
    bad "review-package: --evolution-diff package contains '$section'"
  fi
done

if grep -qF "evo after" "$EVO_PKG" 2>/dev/null; then
  ok "review-package: --evolution-diff Diff shows the content the rewrite changed"
else
  bad "review-package: --evolution-diff Diff shows the content the rewrite changed"
fi

case "$(basename "$EVO_PKG")" in
  evolution-*-*..*.diff) ok "review-package: --evolution-diff default filename starts with evolution- and embeds both commit prefixes" ;;
  *) bad "review-package: --evolution-diff default filename shape" "got $(basename "$EVO_PKG")" ;;
esac

# happy path negative: the commit-id-shaped warning must not appear on stderr
# in evolution mode — a commit id is the expected currency for BASE here.
warn=$("$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$EVO_BASE" "$EVO_CHANGE" 2>&1 >/dev/null || true)
case "$warn" in
  *"is a COMMIT id"*) bad "review-package: --evolution-diff suppresses the commit-id warning for BASE" "stderr was: $warn" ;;
  *) ok "review-package: --evolution-diff suppresses the commit-id warning for BASE" ;;
esac

# minor: the same-change teach error's rerun command must include an
# explicit OUTFILE when the caller passed one — the plan calls this out
# explicitly, and it's part of "the caller's own arguments substituted in
# verbatim", not just the three positional ones.
err=$("$SCRIPTS/sdd-review-package" plan.md "$EVO_BASE" "$EVO_CHANGE" "$repo/teach-out.diff" 2>&1 >/dev/null || true)
case "$err" in
  *"$SCRIPTS/sdd-review-package --evolution-diff plan.md $EVO_BASE $EVO_CHANGE $repo/teach-out.diff"*)
    ok "review-package: same-change hidden BASE's rerun command includes an explicit OUTFILE" ;;
  *) bad "review-package: same-change hidden BASE's rerun command includes an explicit OUTFILE" "stderr was: $err" ;;
esac

# minor: HEAD hidden still errors under --evolution-diff. The flag lets BASE
# name a pre-fix copy; it never lets HEAD be one. This needs a THIRD state of
# the evo change — EVO_BASE (v1) as BASE and EVO_CHANGE's current commit (v2)
# as HEAD would trip the new C1 predecessor guard first (v2 is v1's
# SUCCESSOR, not on v1's own evolog, since evolog only looks backward), never
# reaching HEAD's hidden check at all. Capture v2's commit id BEFORE
# superseding it, then rewrite once more: v1 (EVO_BASE) stays hidden and IS
# v2's predecessor (so C1 passes), v2 (EVO_MID) becomes hidden in turn (so
# HEAD's own check is what fires), and EVO_CHANGE now resolves to v3.
EVO_MID=$(jj log -r "$EVO_CHANGE" --no-graph -T 'commit_id.short()')
echo "evo third" > evo.txt
jj describe -m "evo task work" >/dev/null 2>&1

hidden=$(jj log -r "$EVO_MID" --no-graph -T 'if(hidden,"hidden","visible")')
[ "$hidden" = "hidden" ] \
  && ok "HEAD-hidden fixture: EVO_MID is really hidden after the third rewrite" \
  || bad "HEAD-hidden fixture: EVO_MID is really hidden after the third rewrite" "got $hidden"

check_fails "review-package: --evolution-diff with hidden HEAD is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$EVO_BASE" "$EVO_MID"
err=$("$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$EVO_BASE" "$EVO_MID" 2>&1 >/dev/null || true)
case "$err" in
  *"bad HEAD:"*"HIDDEN"*) ok "review-package: --evolution-diff hidden HEAD names the hazard" ;;
  *) bad "review-package: --evolution-diff hidden HEAD names the hazard" "stderr was: $err" ;;
esac

# --- sdd-review-package: BASE's checks run before HEAD's --------------------
#
# The pre-task script resolved and fully checked BASE before ever resolving
# HEAD. Evolution mode needs HEAD's change id available earlier (to compare
# against BASE's), but "resolved early" must not become "checked early": a
# reordering that ran HEAD's hidden check first would (a) silently drop
# BASE's commit-id-shape warning whenever HEAD is also hidden — the script
# would exit on HEAD before BASE's warning ever printed — and (b), for a
# BASE-and-HEAD-both-hidden pair, report HEAD's hidden error first instead of
# BASE's, where the original script reported BASE's.

# fixture-is-honest: T1_COMMIT and EVO_BASE really are both hidden (and are
# from different changes — T1_CHANGE vs EVO_CHANGE, already proven above).
hidden=$(jj log -r "$T1_COMMIT" --no-graph -T 'if(hidden,"hidden","visible")')
[ "$hidden" = "hidden" ] \
  && ok "precedence fixture: T1_COMMIT is really hidden" \
  || bad "precedence fixture: T1_COMMIT is really hidden" "got $hidden"

hidden=$(jj log -r "$EVO_BASE" --no-graph -T 'if(hidden,"hidden","visible")')
[ "$hidden" = "hidden" ] \
  && ok "precedence fixture: EVO_BASE is really hidden" \
  || bad "precedence fixture: EVO_BASE is really hidden" "got $hidden"

# fails-correctly: DEFAULT mode, BASE and HEAD both hidden and from DIFFERENT
# changes -> exit 2, and BASE's hidden error is the one reported. The
# original script never got far enough to check HEAD at all in this case.
check_fails "review-package: BASE and HEAD both hidden (different changes) is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" plan.md "$T1_COMMIT" "$EVO_BASE"
err=$("$SCRIPTS/sdd-review-package" plan.md "$T1_COMMIT" "$EVO_BASE" 2>&1 >/dev/null || true)
case "$err" in
  "bad BASE:"*) ok "review-package: both-hidden different-changes reports BASE's hidden error, not HEAD's" ;;
  *) bad "review-package: both-hidden different-changes reports BASE's hidden error, not HEAD's" "stderr was: $err" ;;
esac

# --- sdd-review-package: C1 — same change id does NOT imply predecessor -----
#
# A `jj op restore` rewind forks the evolution: it abandons one branch of a
# change's history while keeping the other, and the abandoned branch's
# commits stay hidden but keep the SAME change id. Without a guard beyond the
# change-id check, that fork's abandoned commit would pass straight through
# to an exit-0 package that silently attributes its content to the round.
#
# Fixture: describe a change (the fork point), capture the operation id right
# there, evolve it once more (branch A), then `jj op restore` back to the
# fork point and evolve it again differently (branch B). Branch A's commit
# shares the change id with branch B's (both are rewrites of the same
# change) but is NOT branch B's predecessor — branch B evolved directly from
# the restored fork point, never passing through branch A.
jj new >/dev/null 2>&1
echo "fork base" > fork.txt
jj describe -m "fork task work" >/dev/null 2>&1
FORK_CHANGE=$(jj log -r 'description(substring:"fork task work")' --no-graph -T 'change_id.short()')
FORK_OP=$(jj op log --no-graph -T 'id.short() ++ "\n"' -n 1)

echo "fork branch A" > fork.txt
jj describe -m "fork task work (branch A)" >/dev/null 2>&1
FORK_A=$(jj log -r "$FORK_CHANGE" --no-graph -T 'commit_id.short()')

jj op restore "$FORK_OP" >/dev/null 2>&1

echo "fork branch B" > fork.txt
jj describe -m "fork task work (branch B)" >/dev/null 2>&1
FORK_B=$(jj log -r "$FORK_CHANGE" --no-graph -T 'commit_id.short()')

# fixture-is-honest: branch A's commit is hidden, shares HEAD's (branch B's)
# change id, and is genuinely ABSENT from branch B's own evolog.
hidden=$(jj log -r "$FORK_A" --no-graph -T 'if(hidden,"hidden","visible")')
[ "$hidden" = "hidden" ] \
  && ok "fork fixture: branch A's commit is really hidden" \
  || bad "fork fixture: branch A's commit is really hidden" "got $hidden"

fork_a_change=$(jj log -r "$FORK_A" --no-graph -T 'change_id.short()')
[ "$fork_a_change" = "$FORK_CHANGE" ] \
  && ok "fork fixture: branch A's commit shares HEAD's change id" \
  || bad "fork fixture: branch A's commit shares HEAD's change id" "got $fork_a_change"

evolog_of_b=$(jj evolog -r "$FORK_B" --no-graph -T 'commit.commit_id() ++ "\n"')
case "$evolog_of_b" in
  *"$FORK_A"*) bad "fork fixture: branch A's commit is really absent from branch B's evolog" ;;
  *) ok "fork fixture: branch A's commit is really absent from branch B's evolog" ;;
esac

# fails-correctly: --evolution-diff with branch A's (abandoned, hidden)
# commit as BASE and the change (now branch B) as HEAD -> exit 2, stderr
# names the predecessor problem — not just "hidden", the fork itself.
check_fails "review-package: --evolution-diff with a forked (op-restore-abandoned) BASE is exit 2" 2 \
  "$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$FORK_A" "$FORK_CHANGE"
err=$("$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$FORK_A" "$FORK_CHANGE" 2>&1 >/dev/null || true)
case "$err" in
  *"bad BASE:"*"evolution chain"*) ok "review-package: forked BASE names the predecessor problem" ;;
  *) bad "review-package: forked BASE names the predecessor problem" "stderr was: $err" ;;
esac

# still-accepts: the existing happy-path evolution case (an honest amend —
# EVO_BASE really is EVO_CHANGE's predecessor) must stay green under the new
# guard. Re-asserted here, after C1 lands, rather than trusted from earlier
# in the file.
check "review-package: --evolution-diff still accepts an honest amend after the C1 guard" \
  "$SCRIPTS/sdd-review-package" --evolution-diff plan.md "$EVO_BASE" "$EVO_CHANGE"

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
