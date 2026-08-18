#!/usr/bin/env bash
# PreToolUse hook: Block raw git commands in jj plugins
# Allows: jj git *, gh *, and any non-git commands
# Blocks: git * (bare git commands, not jj git subcommands)

input=$(cat)

# Gate on jj-repo presence (#45). This hard wall is intended only inside a jj
# repo. Installed at the user (global) level the hook fires in every project,
# and blocking git in a non-jj project is collateral damage, not the design.
# Detect a .jj directory at cwd or any ancestor; if absent, pass through so git
# is allowed. The walk stops at a dirname fixed point, which checks "/" too and
# never hangs on a relative cwd (dirname "." == "."). bash 3.2-safe: no
# globstar, no associative arrays.
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] || cwd="$PWD"
jj_repo=false
dir="$cwd"
prev=""
while [ -n "$dir" ] && [ "$dir" != "$prev" ]; do
  if [ -d "$dir/.jj" ]; then
    jj_repo=true
    break
  fi
  prev="$dir"
  dir=$(dirname "$dir")
done
[ "$jj_repo" = true ] || exit 0

command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Normalize: collapse newlines
command_normalized=$(echo "$command" | tr '\n' ';')

# Check for bare "git " commands, one clause at a time (#101).
#
# This used to ask two questions over the WHOLE command string: "is there a git
# at command position" and "is there a jj git at command position". One
# `jj git …` token anywhere exempted every other clause, so
# `jj git fetch && git reset --hard origin/main` was allowed even though the
# second clause is denied on its own. Chaining a fetch onto another command is
# ordinary model output, not an evasion, so the seam was reachable by accident.
#
# The fix: split on the clause separators the old pattern already treated as
# command-position boundaries (; & |) and decide each clause alone. `tr` maps
# each character independently, so `&&` and `||` produce an empty clause in
# between, which matches nothing and is skipped; `2>&1` likewise splits
# harmlessly. Newlines were folded to `;` above, so multi-line commands split
# here too. grep anchors `^` per line, i.e. per clause.
#
# The jj-git exemption is now structural rather than a second regex: a clause
# invoking `jj git …` begins with `jj`, so it can never match a
# command-position `git`. `jj git push` (used by /commit-push-pr and /finish)
# stays allowed, in any position of any compound.
#
# Deliberately quote-blind, exactly as the previous regex was: a separator
# inside quotes still starts a clause, and prose mentioning a git command
# mid-clause (`jj describe -m 'replaces git status'`) is still not at command
# position and still passes. bash 3.2-safe: no globstar, no associative arrays.
#
# #105 widened "command position" beyond `; & |`. Three shapes reached a real
# git invocation without one of those characters immediately before it, and 20
# of 21 measured cases were ALLOWED:
#
#   1. Substitution — `$(git …)`, `<(git …)`. The sed pass rewrites each opening
#      sigil to `;` so the substituted command starts a clause.
#   2. Grouping — `(git …)`, `{ git …; }`. A subshell or brace group can only
#      open where a command may start, i.e. at the head of a clause, so this is
#      a strippable clause prefix rather than a separator.
#   3. Prefix words — a keyword (`if`, `then`, `do`, `!`, …), a zero-argument
#      wrapper (`env`, `time`, `nice`, …), or an environment assignment before
#      the command. Stripped by the `(…)*` repetition, so they stack:
#      `then GIT_X=1 git reset` is caught by one pass.
#
# The jj-git exemption stays structural and survives all of this: strip the
# prefixes off `( JJ_USER=ci jj git push )` and the clause still starts with
# `jj`, so it can never match a command-position `git`.
#
# WHERE THE LINE IS, and why it is here. This matcher is quote-blind, so every
# character it treats as a boundary also fires inside a quoted string. Two
# rules in the first cut of this fix were withdrawn after review for exactly
# that reason, having been shipped past a must-allow corpus written by the same
# pass that wrote them:
#
#   - Rewriting every backtick to a separator denied `git` in a markdown code
#     span. Opening and closing backticks are indistinguishable without pairing
#     and pairing is impossible quote-blind, so this cannot be narrowed — it is
#     the whole rule or none of it. None of it: /finish and /commit-push-pr both
#     instruct writing a PR body inline, and a body naming a git command in
#     backticks could not be submitted.
#   - Rewriting every `) ` to a separator denied parenthesised prose followed by
#     the word git (`-m 'per (#101) git is blocked'`). It bought only the
#     case-statement pattern `a) git status`, the rarest shape in the set.
#
# The assignment prefix keeps quoted values whole for the same reason: stopping
# at the first space left `git ` at the head of `MSG="a git b" jj describe`.
# The unquoted alternative excludes quote characters so it cannot win by
# matching a shorter prefix — grep needs only SOME alternative to match, so a
# permissive branch defeats a stricter one sitting beside it.
#
# Known-open, and pinned by pass-through assertions in test-block-raw-git.sh:
# backtick substitution, case patterns, an interpreter handed git as data
# (`bash -c 'git status'`), wrappers carrying their own options
# (`eval "git …"`, `sudo -u me git`, `timeout 5 git`), and spellings other than
# the bare word (`/usr/bin/git`, `\git`). The internals pattern below is open in
# the mirror direction: being quote-blind, it denies prose that names the `.git`
# directory. All need argument parsing or quote tracking, i.e. a shell parser. The wall is a
# guardrail against habit, not a sandbox — anyone who wants git can disable the
# plugin. Reaching further with a regex is what produced the false positives.
sq="'"
dq='"'
# VAR=value, VAR="value with spaces", VAR='…', and concatenations of those
# (VAR="a"b is one word to the shell). The value is a SEQUENCE of runs, not a
# choice between them: a single alternation stops after the first run and then
# demands whitespace, so VAR="a"b git status slipped through.
assign_re="[A-Za-z_][A-Za-z0-9_]*=(${dq}[^${dq}]*${dq}|${sq}[^${sq}]*${sq}|[^[:space:]${dq}${sq}])*"
wrappers_re='if|then|elif|else|do|while|until|!|time|command|exec|env|eval|nohup|nice|sudo|xargs'
prefix_re="(([({][[:space:]]*)|((${assign_re}|${wrappers_re})[[:space:]]+))*"

# Keep the offending clause, not just the yes/no answer (#115): the suggestion
# is keyed on what was actually attempted, and in a compound command only one
# clause is the offender — `jj git fetch && git stash` must be answered about
# stash, not about fetch. `head -n 1` takes the first offender, which is the one
# the shell would have reached first.
raw_git_clause=$(printf '%s\n' "$command_normalized" \
   | sed -E -e 's/\$\(/;/g' -e 's/[<>]\(/;/g' \
   | tr ';&|' '\n\n\n' \
   | grep -E "^[[:space:]]*${prefix_re}git[[:space:]]" \
   | head -n 1)

has_raw_git=false
[ -n "$raw_git_clause" ] && has_raw_git=true

# The attempted subcommand: the first word after the command-position `git`.
# Stripping with the same prefix pattern that matched means every shape #105
# taught the matcher to see through — substitution, grouping, keywords,
# assignments — is keyed correctly instead of falling back.
#
# Truncating at the first character outside [a-z-] cleans up what the clause
# splitter leaves behind (`echo $(git stash)` arrives here as `git stash)`).
# It also, deliberately, leaves an option in the subcommand slot unmatched:
# `git -C dir status` yields `-c`, hits no case arm, and gets the generic list.
# Resolving that would need argument parsing — the line this file does not
# cross, per the boundary note above — so the fallback is the correct answer
# there, not a missed case.
git_subcommand=""
if [ "$has_raw_git" = true ]; then
  git_subcommand=$(printf '%s\n' "$raw_git_clause" \
    | sed -E "s/^[[:space:]]*${prefix_re}git[[:space:]]+//" \
    | awk '{print $1}' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E -e "s/^[${sq}${dq}]+//" -e 's/[^a-z-].*$//')
fi

# Direct access to the git directory. `.git` must be a WHOLE PATH COMPONENT:
# preceded by start-of-string or a character that cannot continue a filename,
# and followed by one that cannot either.
#
# This was `(\.git/|\.git[[:space:]]|git\s+config|git\s+rev-parse)`, and both
# halves of it were wrong:
#
#   - The `.git` alternatives were UNANCHORED, so any .git-suffixed token with
#     another word after it was denied. `jj git clone <url>.git <dir>` — the
#     command this very file recommends for `git clone` — was blocked, as were
#     `gh repo clone o/r.git dir` (gh is exempt by name in CLAUDE.md) and
#     `npm i <url>.git --save`. Meanwhile bare `ls .git` PASSED, since a
#     trailing slash or space was required. One missing anchor caused both the
#     false positives and the gap. Closing the gap was previously thought to
#     require accepting the URL denials as their price; that was a misreading of
#     the cause, and anchoring fixes both directions at once.
#
#   - The plumbing alternatives added no coverage. The raw-git branch above
#     returns first for any clause whose command is a bare `git`, so
#     `git config` and `git rev-parse` at command position were always answered
#     there — and now get keyed advice. All these alternatives contributed was a
#     deny for the NAMES appearing in prose: `-m 'replaces git rev-parse'` was
#     blocked while the byte-identical `-m 'replaces git status'` passed.
#
# `.gitignore`, `.gitattributes` and `.github/` are longer names rather than the
# directory itself and must keep passing — this repo's own CI lives in
# `.github/`. Still quote-blind, so prose naming the directory is denied; that
# is pinned as a known-open shape rather than fixed, because telling a path from
# a quoted mention needs a shell parser.
#
# EXCLUSION idioms are stripped before the test, because they are the mirror
# image of what this branch is for: `find . -path ./REPO -prune -o …` and
# `grep -r --exclude-dir=REPO` (REPO being the directory named below) mention it
# in order to STAY OUT of it. Denying those taught nothing and cost a rewrite
# every time — the wall is a guardrail against habit, and reaching for the
# directory in order to skip it is not the habit in question.
#
# This is a carve-out, not a general answer to the quote-blindness noted above.
# The shapes below are FLAG-ANCHORED: each strips one option together with its
# own argument, a fixed token sequence rather than a quoted region needing a
# parser. Everything else behaves exactly as before, and crucially the strip
# removes only the exclusion token itself — a command that both excludes the
# directory and then reads a file inside it still denies, because the second
# mention survives the strip. A carve-out that cleared every mention once one
# was benign would be a hole, not a fix.
#
# `-prune` is required on the find form deliberately. `-path X -prune` skips the
# directory; the same test without `-prune` is a SEARCH for it, which is exactly
# what this branch exists to answer.
internals_scan=$(printf '%s\n' "$command_normalized" | sed -E \
  -e "s/--exclude(-dir)?=[${sq}${dq}]?[^[:space:]${sq}${dq}]*\.git[${sq}${dq}]?//g" \
  -e "s/--exclude(-dir)?[[:space:]]+[${sq}${dq}]?[^[:space:]${sq}${dq}]*\.git[${sq}${dq}]?//g" \
  -e "s/(!|-not)?[[:space:]]*-(path|wholename|name|iname|regex)[[:space:]]+[${sq}${dq}]?[^[:space:]${sq}${dq}]*\.git[^[:space:]${sq}${dq}]*[${sq}${dq}]?[[:space:]]+-prune//g" \
  -e "s/(!|-not)[[:space:]]+-(path|wholename|name|iname|regex)[[:space:]]+[${sq}${dq}]?[^[:space:]${sq}${dq}]*\.git[^[:space:]${sq}${dq}]*[${sq}${dq}]?//g")

has_git_internals=false
if printf '%s\n' "$internals_scan" \
   | grep -qE '(^|[^A-Za-z0-9._-])\.git([^A-Za-z0-9_-]|$)'; then
  has_git_internals=true
fi

# The reason is built with `jq --arg`, not a heredoc: it now carries newlines
# and backticks and varies with the input, and hand-escaping that into a JSON
# string literal is how a hook starts emitting malformed JSON on exactly the
# inputs nobody tested. jq is already required above.
deny() {
  jq -n --arg reason "$1" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
}

# ---------------------------------------------------------------------------
# git subcommand → jj recommendation (#115)
#
# A recommendation is a claim that the command exists, and that claim rots.
# Measured against jj 0.43.0: `jj branch`, `jj checkout` and `jj merge` are all
# gone, and `jj backout` — the obvious spelling for git revert — is now
# `jj revert`. A stale suggestion is worse than a generic one, because a
# plausible command gets executed.
#
# So every jj command named below sits inside `backticks`, and
# .github/tests/test-jj-recommendations.sh drives this hook, pulls out what is
# between the backticks and requires `jj <that> --help` to exit 0. Keep prose
# outside the backticks or the lint will try to run it.
#
# Three classes, and the middle one is the whole point:
#
#   exact             one jj answer — emit it.
#   intent-dependent  several answers depending on what was meant — present
#                     them all. Collapsing these to one confident suggestion is
#                     the failure mode, because the caller then runs it.
#   no equivalent     say so, and say why. Never invent one.
# ---------------------------------------------------------------------------
suggest_for() {
  case "$1" in
    # --- exact -------------------------------------------------------------
    status)      echo 'git status → `jj status`' ;;
    log)         echo 'git log → `jj log`' ;;
    diff)        echo 'git diff → `jj diff`' ;;
    show)        echo 'git show → `jj show`' ;;
    blame)       echo 'git blame → `jj file annotate`' ;;
    annotate)    echo 'git annotate → `jj file annotate`' ;;
    rebase)      echo 'git rebase → `jj rebase`' ;;
    push)        echo 'git push → `jj git push` (the jj git subcommands are allowed; only bare git is blocked)' ;;
    fetch)       echo 'git fetch → `jj git fetch`' ;;
    clone)       echo 'git clone → `jj git clone`' ;;
    init)        echo 'git init → `jj git init`' ;;
    remote)      echo 'git remote → `jj git remote list`, and `jj git remote add` to add one' ;;
    revert)      echo 'git revert → `jj revert` (this is the current spelling; jj backout was removed)' ;;
    # `jj bisect` alone is a subcommand GROUP and exits 2; the runnable leaf is
    # `jj bisect run`. --help exits 0 for both, so the recommendations lint now
    # rejects groups explicitly rather than trusting the exit code.
    bisect)      echo 'git bisect → `jj bisect run` with a command that tests the revision' ;;
    bookmark)    echo 'git bookmark is not a git command; jj bookmarks are managed with `jj bookmark list`' ;;
    worktree)    echo 'git worktree → `jj workspace list`, `jj workspace add`, `jj workspace forget`' ;;
    restore)     echo 'git restore → `jj restore`' ;;
    rev-parse)   echo 'git rev-parse HEAD → `jj log -r @ --no-graph -T commit_id`' ;;

    # --- intent-dependent --------------------------------------------------
    reset)
      cat <<'EOF'
git reset has more than one jj answer. Pick the one matching your intent:
  - discard the change entirely  → `jj abandon`
  - restore file contents        → `jj restore`
  - rewind the whole repo state  → `jj op restore`
EOF
      ;;
    checkout)
      cat <<'EOF'
git checkout has more than one jj answer. Pick the one matching your intent:
  - move to an existing change     → `jj edit`
  - start a new change on top      → `jj new`
  - restore a file from a revision → `jj restore`
EOF
      ;;
    # Its own arm, not folded into checkout. git switch exists precisely to
    # split checkout's overloaded roles, so answering it with checkout's
    # ambiguity — and with a restore-a-file option switch cannot express —
    # re-introduces the confusion the caller avoided by typing switch, and names
    # a command they did not run.
    switch)
      cat <<'EOF'
git switch has more than one jj answer. Pick the one matching your intent:
  - move to an existing change → `jj edit`
  - start a new change on top  → `jj new`
EOF
      ;;
    commit)
      cat <<'EOF'
In jj the working copy IS already a commit, so there is nothing to create:
  - set its description                 → `jj describe`
  - finalize it and start a new change  → `jj commit`
EOF
      ;;
    pull)
      cat <<'EOF'
git pull is two operations in jj — run them separately:
  - `jj git fetch`
  - then `jj rebase` onto the updated trunk
EOF
      ;;
    branch)
      cat <<'EOF'
jj calls these bookmarks:
  - list           → `jj bookmark list`
  - create or move → `jj bookmark set`
  - delete         → `jj bookmark delete`
EOF
      ;;
    merge)
      cat <<'EOF'
git merge has more than one jj answer. Pick the one matching your intent:
  - create a merge change → `jj new` given two revisions
  - integrate linearly    → `jj rebase`
EOF
      ;;
    cherry-pick)
      cat <<'EOF'
git cherry-pick has more than one jj answer. Pick the one matching your intent:
  - copy a change elsewhere  → `jj duplicate`
  - move it instead of copy  → `jj rebase`
EOF
      ;;
    config)
      cat <<'EOF'
git config has more than one jj answer. Pick the one matching your intent:
  - read   → `jj config list`
  - write  → `jj config set`
EOF
      ;;
    reflog)
      cat <<'EOF'
git reflog has more than one jj answer. Pick the one matching your intent:
  - repo-wide operation history → `jj op log`
  - one change's own history    → `jj evolog`
  - undo the last operation     → `jj undo`
EOF
      ;;
    tag)
      cat <<'EOF'
jj can list tags but not create them:
  - list → `jj tag list`
  - to publish a release tag, use the gh CLI
EOF
      ;;

    # --- no equivalent -----------------------------------------------------
    add)
      cat <<'EOF'
No jj equivalent, and none is needed: jj tracks working-copy changes
automatically and has no staging area. There is nothing to add.
EOF
      ;;
    stash)
      cat <<'EOF'
No jj equivalent, and none is needed: the working copy IS a commit, so work in
progress is already saved.
  - park it and start something else → `jj new`
  - come back to it later            → `jj edit`
EOF
      ;;
    mv|rm)
      cat <<'EOF'
No jj equivalent, and none is needed: use plain mv or rm. jj snapshots the
working copy, so the change is recorded without a VCS-level command.
EOF
      ;;
    clean)
      cat <<'EOF'
No direct jj equivalent. `jj restore` reverts tracked files; files jj never
tracked are not jj's to delete — remove those with rm.
EOF
      ;;
    grep)
      cat <<'EOF'
No jj equivalent, and none is needed: ordinary grep works on the working copy.
`jj file list` enumerates tracked paths if you need to scope the search.
EOF
      ;;

    # --- unmapped ----------------------------------------------------------
    # Everything not named above, plus the empty subcommand produced by a
    # leading option. The generic list is the honest answer here: it says what
    # is broadly true without claiming to know what was meant.
    *)
      cat <<'EOF'
Use jj equivalents: git log → `jj log`, git diff → `jj diff`,
git status → `jj status`, git blame → `jj file annotate`,
git remote → `jj git remote list`, git push → `jj git push`.
EOF
      ;;
  esac
}

if [ "$has_raw_git" = true ]; then
  deny "BLOCKED: Raw git commands are not allowed in jj repos.
$(suggest_for "$git_subcommand")
For GitHub operations, use the gh CLI."
  exit 0
fi

# This branch now answers .git path access and nothing else — literally, not
# just "in practice": the plumbing alternatives were removed from the pattern
# above, so the only way to reach here is a real path component.
#
# The message therefore describes intents rather than naming commands it claims
# to intercept. It used to advertise `ls .git/ → not needed` while the bare
# `ls .git` passed straight through — a rule enforced for one spelling and
# advertised for both (#115). Both halves of that mismatch are now fixed: the
# bare form is enforced, and the message no longer names commands this branch
# does not handle.
if [ "$has_git_internals" = true ]; then
  deny "BLOCKED: Git internals access detected. This project uses jj (Jujutsu), and the git directory is an implementation detail of its backend — read jj's own state instead:
  - where the repo lives    → \`jj root\`
  - the current commit hash → \`jj log -r @ --no-graph -T commit_id\`
  - configuration           → \`jj config list\` and \`jj config set\`
  - remotes                 → \`jj git remote list\`"
  exit 0
fi

exit 0
