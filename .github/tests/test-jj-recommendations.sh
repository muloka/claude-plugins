#!/usr/bin/env bash
# Every jj command the raw-git wall recommends must actually exist (#115).
#
# Recommending a command is a claim that the command exists, and the claim rots
# without anyone noticing: the wall still denies, the message still looks
# authoritative, and the suggestion is now a command jj removed. That is worse
# than the old generic list, because a plausible suggestion gets executed.
#
# Measured against jj 0.43.0 while writing the table this lint guards:
#
#     OK      jj bookmark list      MISSING jj branch      (renamed)
#     OK      jj file annotate      MISSING jj checkout    (removed)
#     OK      jj op restore         MISSING jj merge       (removed)
#     OK      jj revert             MISSING jj backout     (renamed)
#     OK      jj undo               MISSING jj op undo     (never existed)
#     OK      jj obslog                                    (deprecated alias)
#
# The last two columns are the point. `jj backout` and `jj op undo` are the
# spellings an author reaches for from memory, and both are dead.
#
# This lives in .github/tests/ rather than under a plugin because it shells out
# to jj and the hook it drives ships byte-identical in three plugins, so it
# belongs to none of them.
#
# Mechanism: drive the hook as a black box and read what it actually emits,
# rather than grepping the source. Source text would also pick up the comments,
# which name dead commands on purpose.
# `-uo pipefail`, deliberately NOT `-euo` as the other suites use. Two commands
# here return non-zero as a normal result rather than as an error: the grep in
# recommendations_in finds nothing for a no-equivalent arm like `add`, which
# names no command at all, and it runs inside a `$(...)` feeding a heredoc where
# -e semantics are murky. Under -e this suite would abort partway through and
# report a pass count that merely reflects where it died. The floor check at the
# end is what guards against silently checking too little.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/plugins/project-setup-jj/scripts/block-raw-git.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

command -v jj >/dev/null 2>&1 || { echo "FAIL - jj is not installed; this lint cannot verify anything"; exit 1; }

JJ_DIR=$(mktemp -d); mkdir -p "$JJ_DIR/.jj"
trap 'rm -rf "$JJ_DIR"' EXIT

# The deny reason for a given command, decoded from the hook's JSON.
reason_for() {
  jq -nc --arg c "$1" --arg d "$JJ_DIR" '{tool_input:{command:$c},cwd:$d}' \
    | /bin/bash "$HOOK" 2>/dev/null \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}

# Recommendations are the backticked spans that start with "jj ". Prose sits
# outside the backticks precisely so this can be mechanical.
recommendations_in() {
  printf '%s' "$1" | grep -oE '`jj[^`]*`' | sed -e 's/^`//' -e 's/`$//'
}

# `jj log -r @ --no-graph -T commit_id`  ->  jj log
# `jj git remote list`                   ->  jj git remote list
#
# Take the leading run of bare lowercase words and stop at the first token that
# is not one (an option, a placeholder, a revset). Over-consuming is harmless
# for leaf commands because --help short-circuits argument parsing, but it is
# NOT harmless for a subcommand group: `jj bookmark nonsense --help` exits 2.
# That asymmetry is deliberate — it means a group path must be spelled right.
jj_path_of() {
  local out="" first=1 tok
  for tok in $1; do
    if [ "$first" = 1 ]; then first=0; continue; fi
    printf '%s' "$tok" | grep -qE '^[a-z][a-z-]*$' || break
    out="$out $tok"
  done
  printf '%s' "${out# }"
}

# The subcommands the hook has a case arm for, read out of the hook itself so a
# newly added arm is covered without editing this file. Anything that stops
# matching here is a silent coverage hole, which is what the floor check below
# is for.
arms_matching() {
  awk '/^suggest_for\(\)/,/^\}/' "$HOOK" \
    | grep -oE "$1" \
    | tr -d ' )' \
    | tr '|' '\n' \
    | sort -u
}

# Indentation-independent. The first version anchored on exactly four spaces, so
# re-indenting suggest_for would drop arms out of the corpus, leave their
# recommendations unresolved, and stay green — a silent coverage hole that no
# absolute floor set below the real count can catch.
ARMS=$(arms_matching '^[[:space:]]*[a-z][a-z|-]*\)')
# The strict form, kept only to cross-check the loose one. If the two disagree,
# one of them is wrong about what an arm looks like, and the corpus is a guess.
ARMS_STRICT=$(arms_matching '^    [a-z|-]+\)')

if [ -z "$ARMS" ]; then
  bad "could not parse any case arms out of $HOOK — extraction has rotted"
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# Inputs to drive: every mapped subcommand, plus the two branches that are not
# reached by a mapped name — the generic fallback and the internals message.
# `.git` is assembled rather than written literally so this file can be edited
# in a session where the wall is live.
DOT_GIT="cat .$(printf 'git')/HEAD"
INPUTS=$(printf '%s\n' $ARMS | sed 's/^/git /')
INPUTS="$INPUTS
git notes list
$DOT_GIT"

checked=0
seen=""

while IFS= read -r input; do
  [ -n "$input" ] || continue
  reason=$(reason_for "$input")
  if [ -z "$reason" ]; then
    bad "hook produced no deny for: $input"
    continue
  fi
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    path=$(jj_path_of "$rec")
    # De-duplicate: the same command is recommended by several arms, and one
    # `jj --help` per distinct path is enough.
    #
    # One key per LINE, matched with grep -qxF. A space-joined string matched by
    # substring silently drops any path that is a space-delimited prefix of one
    # already seen — `jj git remote` reads as present once `jj git remote list`
    # has been checked, so it would never be verified at all. Nothing in the
    # table hits that today, but `jj config`, `jj op`, `jj bookmark` and
    # `jj workspace` are each one recommendation away from it, and the failure
    # is silent: a skipped path looks exactly like a passing one.
    key="${path:-jj}"
    printf '%s\n' "$seen" | grep -qxF "$key" && continue
    seen="$seen
$key"
    checked=$((checked+1))
    # shellcheck disable=SC2086
    if ! jj $path --help >/dev/null 2>&1; then
      bad "recommendation does NOT resolve: jj $path (from '$rec', suggested for '$input')"
    # Resolving is not enough — it must be RUNNABLE. clap exits 0 from --help
    # for a subcommand GROUP exactly as for a leaf, so `jj bisect` passed the
    # resolve check while `jj bisect` with no args exits 2: the lint certified a
    # recommendation the user cannot run. A group lists its children under a
    # `Commands:` heading; a leaf never does.
    # shellcheck disable=SC2086
    elif jj $path --help 2>&1 | grep -qE '^Commands:'; then
      bad "recommendation is a subcommand GROUP, not runnable: jj $path (from '$rec', suggested for '$input')"
    else
      ok "recommendation resolves and is runnable: jj $path"
    fi
  done <<REC
$(recommendations_in "$reason")
REC
done <<IN
$INPUTS
IN

# Arm extraction must agree with itself. This is the precise guard against
# coverage silently shrinking; the numeric floor below is only a backstop for
# total collapse, and a floor set safely under the real count (15 against an
# actual 36) can by construction miss more than half the table going dark.
n_arms=$(printf '%s\n' "$ARMS" | grep -c . || true)
n_strict=$(printf '%s\n' "$ARMS_STRICT" | grep -c . || true)
if [ "$n_arms" = "$n_strict" ]; then
  ok "arm extraction agrees across both patterns ($n_arms arms)"
else
  bad "arm extraction disagrees: indentation-independent found $n_arms, four-space found $n_strict — the corpus is a guess"
fi

# A lint that silently checked nothing would pass. #82 was exactly this shape:
# a glob that matched no files and therefore never failed.
if [ "$checked" -ge 30 ]; then
  ok "extracted and checked $checked distinct recommendations"
else
  bad "only $checked recommendations checked — extraction is probably broken, not the table"
fi

# Which git commands must get a specific answer rather than the generic list.
#
# This list is written from git's own command set, NOT parsed out of the hook,
# and that independence is the entire point. The first version of this check
# derived its corpus from the hook's case labels, so renaming an arm renamed the
# corpus with it: mutating `stash)` to `stashh)` left the check green while
# `git stash` silently fell through to the generic list — the exact defect #115
# was filed about. A corpus generated from the artifact under test cannot detect
# that artifact's drift.
#
# So: keep this list in sync with git, not with the hook. An entry here that the
# hook does not map is a finding, not a test bug. `git restore` was added to the
# hook because writing this list surfaced that it had no arm.
GIT_COMMANDS="add blame bisect branch checkout cherry-pick clean clone commit
config diff fetch grep init log merge mv pull push rebase reflog remote reset
restore rev-parse revert rm show stash status switch tag worktree"

FALLBACK_MARK='Use jj equivalents: git log'
for gc in $GIT_COMMANDS; do
  reason=$(reason_for "git $gc")
  # The empty guard is load-bearing, not defensive. Testing only for ABSENCE of
  # the fallback marker is satisfied by a hook that returns NOTHING — jq missing
  # from PATH, an allowlist added upstream, deny() writing to stderr — and all
  # 33 iterations would then report "gets a specific answer" while nothing was
  # being denied at all. That is the same self-satisfying assertion this file
  # already had to fix once, in the loop this one replaced.
  if [ -z "$reason" ]; then
    bad "'git $gc' produced no deny at all — the hook answered nothing"
  elif printf '%s' "$reason" | grep -qF "$FALLBACK_MARK"; then
    bad "'git $gc' is not specifically mapped — it fell through to the generic list"
  else
    ok "'git $gc' gets a specific answer"
  fi
done

# The fallback itself must still work. Asserting only the above would be
# satisfied by a hook that answered everything specifically and had no fallback
# at all, which is not what is wanted: an unmapped subcommand should get the
# broad advice, not a wrong guess.
for unmapped in "git notes list" "git submodule update" "git -C /tmp status"; do
  reason=$(reason_for "$unmapped")
  if printf '%s' "$reason" | grep -qF "$FALLBACK_MARK"; then
    ok "unmapped input falls back to the generic list: $unmapped"
  else
    bad "unmapped input did not reach the generic list: $unmapped (got: $reason)"
  fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
