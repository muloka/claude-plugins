#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# project-setup-jj is the canonical superset copy; behaviour is tested against
# it, and the drift-guard proves the remaining copy is byte-identical.
HOOK="$REPO_ROOT/plugins/project-setup-jj/scripts/block-raw-git.sh"

# commit-commands-jj shipped a third copy until #128. It now depends on
# project-setup-jj rather than standing alone, so this suite became the only
# guard for the must-allow shapes /finish and /commit-push-pr write — see the
# #105 block below, which already names both commands. That plugin's own
# tests/test-block-raw-git-gating.sh was deleted alongside its copy; all 20 of
# its assertions were already duplicated here, verified case by case first.
COPIES="plugins/peer-review-jj/scripts/block-raw-git.sh
plugins/project-setup-jj/scripts/block-raw-git.sh"

pass=0
fail=0

# Run the hook with a command + cwd; capture stdout (hook never uses stderr).
#
# The payload is built with `jq --arg`, not string interpolation. Interpolation
# cannot express a command containing a double quote — it produces malformed
# JSON, the hook's `jq -r` yields an empty command, and the case then passes
# for the wrong reason (nothing to block is not the same as nothing blocked).
# The #105 must-allow corpus is full of such commands (`jq '… ["Bash(git *)"]'`,
# `-T 'if(empty, "empty", …)'`), and those are exactly the cases most likely to
# regress. Pass a real newline with $'…' where a multi-line command is meant.
run_hook() {
  local cmd="$1"
  local cwd="$2"
  local json
  json=$(jq -nc --arg c "$cmd" --arg d "$cwd" \
    '{tool_input:{command:$c}, tool_name:"Bash", hook_event_name:"PreToolUse", cwd:$d}')
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

# The deny text itself, decoded. #115 made it vary with the attempted
# subcommand, so "was it denied" is no longer the whole assertion — a hook that
# denies everything with the wrong advice still passes assert_blocked.
deny_reason() {
  run_hook "$1" "$2" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}

# grep -F throughout: the needles are literal command text full of regex
# metacharacters (`jj log -r @ --no-graph -T commit_id`, `jj rebase -d main`),
# and an unescaped one silently changes what is being asserted.
assert_reason_has() {
  local name="$1" cmd="$2" cwd="$3"; shift 3
  local reason missing=""
  reason=$(deny_reason "$cmd" "$cwd")
  for needle in "$@"; do
    printf '%s' "$reason" | grep -qF "$needle" || missing="$missing '$needle'"
  done
  if [ -z "$missing" ]; then
    echo "  PASS: $name"; pass=$((pass + 1))
  else
    echo "  FAIL: $name — reason lacked$missing; got: $reason"; fail=$((fail + 1))
  fi
}

assert_reason_lacks() {
  local name="$1" cmd="$2" cwd="$3"; shift 3
  local reason present=""
  reason=$(deny_reason "$cmd" "$cwd")
  for needle in "$@"; do
    printf '%s' "$reason" | grep -qF "$needle" && present="$present '$needle'"
  done
  if [ -z "$present" ]; then
    echo "  PASS: $name"; pass=$((pass + 1))
  else
    echo "  FAIL: $name — reason should not name$present; got: $reason"; fail=$((fail + 1))
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
# split the same way. $'…' makes the newline real in the shell string; run_hook
# encodes it for the hook.
assert_blocked "multi-line: newline is a separator" $'jj git fetch\ngit reset --hard origin/main' "$JJ_DIR"

# #105: three further shapes put git at a real command position without a
# `; & |` immediately before it, so the per-clause anchor from #101 never saw
# them. Measured against the pre-fix hook, 20 of the 21 cases below came back
# ALLOWED. They are grouped by the family they belong to; each family is closed
# by a different part of the fix, so a regression in one must not be masked by
# the others.
echo "=== jj repo: git at command position without a clause separator (#105) ==="

# Family 1 — command substitution. The character before `git` is `(`, which was
# not a separator. Process substitution is the same mechanism with a different
# sigil. Backticks are deliberately NOT covered — see the boundary section.
assert_blocked "substitution: \$( )"          'echo $(git status)'                  "$JJ_DIR"
assert_blocked "substitution: assignment"     'x=$(git log --oneline)'              "$JJ_DIR"
assert_blocked "substitution: in a for list"  'for f in $(git ls-files); do echo $f; done' "$JJ_DIR"
assert_blocked "substitution: process <( )"   'diff <(git log) /dev/null'           "$JJ_DIR"

# Family 2 — grouping. A subshell or brace group opens a new command position,
# but `(` and `{` were not separators, so the clause began with the grouping
# character instead of with git.
assert_blocked "grouping: subshell"           '(git status)'                        "$JJ_DIR"
assert_blocked "grouping: subshell, spaced"   '( git reset --hard origin/main )'    "$JJ_DIR"
assert_blocked "grouping: brace group"        '{ git status; }'                     "$JJ_DIR"
assert_blocked "grouping: brace after clause" 'true; { git log --oneline; }'        "$JJ_DIR"
assert_blocked "grouping: nested in keyword"  'if true; then (git status); fi'      "$JJ_DIR"

# Family 3 — prefix words. The clause genuinely starts with a shell keyword or
# an environment assignment, so the anchor did not fire even though git runs.
assert_blocked "prefix: if test position"     'if git diff --quiet; then echo clean; fi' "$JJ_DIR"
assert_blocked "prefix: while test position"  'while git pull; do echo again; done' "$JJ_DIR"
assert_blocked "prefix: do body"              'for f in a b; do git add $f; done'   "$JJ_DIR"
assert_blocked "prefix: env assignment"       'GIT_AUTHOR_NAME=x git commit -m y'   "$JJ_DIR"
assert_blocked "prefix: quoted assignment"    'GIT_MSG="a b" git commit -F -'       "$JJ_DIR"
# A shell word may concatenate quoted and unquoted runs. Treating the value as
# a single run stopped after the first and then demanded whitespace, so these
# two slipped through the first version of the quoted-assignment fix.
assert_blocked "prefix: quote-then-bare value" 'FOO="a"b git status'                "$JJ_DIR"
assert_blocked "prefix: bare-then-quote value" 'FOO=a"b" git status'                "$JJ_DIR"
assert_blocked "prefix: two assignments"       'A="x y" B=2 git reset --hard origin/main' "$JJ_DIR"
assert_blocked "prefix: time"                 'time git status'                     "$JJ_DIR"
assert_blocked "prefix: negation"             '! git diff --quiet'                  "$JJ_DIR"
assert_blocked "prefix: env"                  'env git status'                      "$JJ_DIR"
assert_blocked "prefix: sudo"                 'sudo git status'                     "$JJ_DIR"
assert_blocked "prefix: nice"                 'nice git status'                     "$JJ_DIR"
assert_blocked "prefix: stacked keyword+assign" 'if [ -d sub ]; then GIT_X=1 git reset --hard origin/main; fi' "$JJ_DIR"

# Not a #105 family — a harness guard. run_hook builds its payload with jq
# precisely so a command containing a double quote survives the trip. If it
# ever goes back to string interpolation the JSON breaks, the hook reads an
# empty command, and every must-allow case below passes vacuously. This case
# fails loudly in that world, because an empty command is never denied.
assert_blocked "double quotes survive the harness" 'git commit -m "wip"'            "$JJ_DIR"

# These are regression guards, not fail-first cases: every one of them passed
# before the #101 per-clause fix and must still pass after it. A false positive
# in this hook is as bad as a bypass — `jj git push` is instructed in the
# command prose of /commit-push-pr and /finish, so a hook that blocks it breaks
# the documented workflow of commit-commands-jj, which since #128 depends on
# this copy rather than shipping its own.
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

# #105 must-allow corpus. Closing the three families above widened what counts
# as a command position, and every character it now keys on — `(`, `{`, `)`,
# backtick, `=` — is ordinary punctuation in jj's own revset and template
# syntax, in shell parameter expansion, and in the permission strings this
# repo's own installer writes. A false positive here is worse than the bypass
# it prevents: these are the shapes the plugins' command prose instructs.
# Every case below was measured ALLOWED against the pre-#105 hook and must
# stay that way.
echo "=== jj repo: #105 must-allow — parens and prefixes that are not git ==="
# jj revset and template syntax is parenthesis-heavy, and a function whose name
# starts with "git" puts that literal string directly before a paren.
#
# SYNTHETIC INPUT, deliberately kept: `git_head()` was REMOVED from revsets and
# templates in jj 0.43, along with `git_refs()`, and as of 0.44 no revset or
# template function puts "git" before a paren — so nothing jj can parse
# currently exercises this case. It is retained as defense-in-depth because the
# hook gates every jj command an agent runs, and the cost of a future
# `git_something()` being denied is a wall that blocks correct work with an
# authoritative-sounding message. Do NOT read this line as live jj syntax:
# running it against 0.43+ is a parse error, not a revset.
assert_passthrough "revset: trunk() range"  "jj log -r 'trunk()..@'"               "$JJ_DIR"
assert_passthrough "revset: bare trunk()"   "jj diff --from trunk() --to @ --stat" "$JJ_DIR"
assert_passthrough "revset: git-prefixed function (synthetic; git_head() is gone since 0.43)" \
                                            "jj log -r 'ancestors(git_head())'"    "$JJ_DIR"
assert_passthrough "revset: grouped+funcs"  "jj log --ignore-working-copy -r '(trunk()..@) & ~empty()' --no-graph -T 'json(self)'" "$JJ_DIR"
assert_passthrough "template: if() with strings" "jj log -r @ --no-graph -T 'if(empty, \"empty\", \"has-content\")'" "$JJ_DIR"
# Substitution and grouping around a jj command — the exemption must stay
# structural, i.e. survive being wrapped rather than depend on clause index.
assert_passthrough "substitution around jj" 'echo $(jj root)'                      "$JJ_DIR"
assert_passthrough "substitution then jj"   'cd $(jj root) && jj status'           "$JJ_DIR"
assert_passthrough "substitution feeds jj git push" "BOOKMARK=\$(jj log -r @ --no-graph -T 'bookmarks') && jj git push --bookmark \"\$BOOKMARK\"" "$JJ_DIR"
assert_passthrough "process substitution, jj" 'diff <(jj log) <(jj log -r @)'      "$JJ_DIR"
assert_passthrough "subshell around jj git"  '( jj git push )'                     "$JJ_DIR"
assert_passthrough "brace group around jj"   '{ jj status; jj log; }'              "$JJ_DIR"
# Prefix words in front of jj must be stripped and then find `jj`, not `git`.
assert_passthrough "assignment then jj git"  'JJ_USER=ci jj git push'              "$JJ_DIR"
assert_passthrough "if test position, jj"    'if jj diff --quiet; then echo clean; fi' "$JJ_DIR"
assert_passthrough "do body, jj"             'for r in a b; do jj show $r; done'   "$JJ_DIR"
assert_passthrough "time, jj"                'time jj status'                      "$JJ_DIR"
# Parameter expansion is `${`, not a command position — this exact string is
# how every plugin.json references its hook.
assert_passthrough "\${VAR} is not a group"  'bash "${CLAUDE_PLUGIN_ROOT}/scripts/block-raw-git.sh"' "$JJ_DIR"
# The permission string project-setup-install.sh writes. `(` here is inside a
# word, not at command position, so it must not open a clause.
assert_passthrough "Bash(git *) permission string" "jq '.permissions.deny += [\"Bash(git *)\"]' .claude/settings.local.json" "$JJ_DIR"
assert_passthrough "Bash(git *) echoed"      "echo 'deny: Bash(git *)'"            "$JJ_DIR"
# Prose naming a git command. The hook is quote-blind, so this is the case most
# at risk from the widened boundary — and the one this repo would hit first,
# since its own commit messages and PR bodies talk about git constantly.
#
# The first two shapes below shipped in the original #105 fix and survived only
# by accident: `(` precedes git, and `)` is followed by a non-space. Code review
# found that both MIRROR IMAGES regressed — a review that generated its own
# corpus instead of reusing the one written alongside the fix. `git` after a
# backtick and `git` after `) ` were denied, which breaks /finish and
# /commit-push-pr: both instruct writing a PR body inline, and a body naming a
# git command in backticks could not be submitted. The two rules responsible
# (rewriting every backtick, and every `) `, to a clause separator) were
# dropped; these assertions pin that they stay dropped.
assert_passthrough "parenthesised prose in -m"   "jj describe -m 'switch from (git status) to jj status'" "$JJ_DIR"
assert_passthrough "parenthesised prose in body" "gh pr create --body 'closes #105 (git wall)'" "$JJ_DIR"
assert_passthrough "backtick code span in -m"    'jj describe -m '"'"'replaces `git status` with jj status'"'"'' "$JJ_DIR"
assert_passthrough "backtick code span in body"  'gh pr create --body '"'"'stop using `git log` here'"'"'' "$JJ_DIR"
assert_passthrough "prose: ) then the word git"  "jj describe -m 'per (#101) git is blocked'" "$JJ_DIR"
assert_passthrough "prose: ) then git in body"   "gh pr comment --body 'see (CONVENTIONS.md) git is denied'" "$JJ_DIR"
# A quoted assignment value is one token to the shell. Stripping only up to the
# first space left `git ` at clause head and denied an ordinary jj command.
assert_passthrough "quoted assignment value naming git" 'MSG="a git b" jj describe -m x' "$JJ_DIR"
# Other tools whose syntax uses the same punctuation.
assert_passthrough "awk brace block"         "jj diff -r @ --summary | awk '{print \$2}'" "$JJ_DIR"
assert_passthrough "find -exec naming git"   'find . -name "*.sh" -exec grep -l git {} \;' "$JJ_DIR"

# Documented boundary. These are NOT desired behaviour — they are shapes the
# wall does not catch, pinned so the READMEs cannot drift away from what the
# hook does. The wall matches text at command position; it does not parse the
# shell, and every attempt to reach further with a regex is what produced the
# false positives above. Closing any of these means updating the scope note in
# all three READMEs and CONVENTIONS.md in the same change.
echo "=== jj repo: documented boundary — known-open shapes (#105) ==="
# Backtick substitution. Dropped deliberately: opening and closing backticks are
# indistinguishable without pairing, and pairing is impossible quote-blind, so
# covering this necessarily denies every code span in prose.
assert_passthrough "boundary: backtick substitution" 'echo `git status`'            "$JJ_DIR"
# Case-statement pattern. Reached only by rewriting every `) ` to a separator,
# which denies parenthesised prose — a much likelier command than this one.
assert_passthrough "boundary: case pattern"  'case $x in a) git status;; esac'      "$JJ_DIR"
# An interpreter handed git as data.
assert_passthrough "boundary: bash -c"       "bash -c 'git status'"                 "$JJ_DIR"
# Wrappers carrying their own options — the alternation strips a bare wrapper
# word only. Matching option-bearing forms needs argument parsing.
assert_passthrough "boundary: eval quoted"   'eval "git reset --hard origin/main"'  "$JJ_DIR"
assert_passthrough "boundary: sudo -u"       'sudo -u me git status'                "$JJ_DIR"
assert_passthrough "boundary: timeout"       'timeout 5 git status'                 "$JJ_DIR"
# Spellings that are not the bare word `git`.
assert_passthrough "boundary: absolute path" '/usr/bin/git status'                  "$JJ_DIR"
assert_passthrough "boundary: escaped word"  '\git status'                          "$JJ_DIR"

# #115. The deny text used to be a fixed heredoc, so `git stash` was answered
# with a list about log/diff/status/blame/remote/push — six suggestions, none of
# them relevant. The wall worked and the advice was noise.
#
# The assertions below are about WHICH advice comes back, so each one names the
# text it expects. They are fail-first: every one of them failed against the
# static heredoc on trunk 0d8dfea8.
echo "=== jj repo: the suggestion is keyed on the attempted subcommand (#115) ==="

# Exact — one jj answer exists, so emit it and nothing else.
#
# Each of these needs a paired `lacks`. The old generic list already named
# jj status, jj log, jj file annotate and jj git push, so a bare `has` passes
# against the static heredoc this section exists to replace — it would be green
# on trunk and green after, measuring nothing. The `lacks` is what distinguishes
# "answered specifically" from "handed the whole list".
# A deny blocks the whole Bash call; the trailer saying so is pinned on a
# compound — the clause before the && is exactly what a reader would
# otherwise assume ran (#173).
assert_reason_has  "deny on a compound says nothing executed (#173)" \
  "mkdir -p out && git status" "$JJ_DIR" 'No part of this command executed'

assert_reason_has  "exact: status"  "git status"           "$JJ_DIR" 'jj status'
assert_reason_lacks "exact: status is not the generic list" \
  "git status" "$JJ_DIR" 'jj file annotate' 'jj git remote list'
assert_reason_has  "exact: log"     "git log --oneline"    "$JJ_DIR" 'jj log'
assert_reason_lacks "exact: log is not the generic list" \
  "git log --oneline" "$JJ_DIR" 'jj file annotate' 'jj git remote list'
assert_reason_has  "exact: blame"   "git blame f.txt"      "$JJ_DIR" 'jj file annotate'
assert_reason_lacks "exact: blame is not the generic list" \
  "git blame f.txt" "$JJ_DIR" 'jj git remote list' 'jj status'
# `git restore` had no case arm until the recommendations lint's independent
# corpus was written against git's command set rather than against the hook's
# own case labels, at which point it showed up as falling to the generic list.
assert_reason_has  "exact: restore"  "git restore f.txt"   "$JJ_DIR" 'jj restore'
assert_reason_lacks "exact: restore is not the generic list" \
  "git restore f.txt" "$JJ_DIR" 'jj file annotate' 'jj git remote list'
assert_reason_has  "exact: push"    "git push origin main" "$JJ_DIR" 'jj git push'
assert_reason_lacks "exact: push is not the generic list" \
  "git push origin main" "$JJ_DIR" 'jj file annotate' 'jj status'

# Intent-dependent — the class that gets got wrong under pressure. Each of
# these has several jj answers depending on what was meant, and the hook must
# present them all. Asserting only "some suggestion came back" would pass
# against a hook that confidently picked one, which is the failure mode: a
# plausible single suggestion gets executed.
assert_reason_has "intent: reset offers all three" \
  "git reset --hard origin/main" "$JJ_DIR" 'jj abandon' 'jj restore' 'jj op restore'
assert_reason_has "intent: checkout offers edit and new" \
  "git checkout main" "$JJ_DIR" 'jj edit' 'jj new'
assert_reason_has "intent: commit offers describe and commit" \
  "git commit -m x" "$JJ_DIR" 'jj describe' 'jj commit'
assert_reason_has "intent: pull is fetch then rebase" \
  "git pull --rebase" "$JJ_DIR" 'jj git fetch' 'jj rebase'
assert_reason_has "intent: branch offers the bookmark verbs" \
  "git branch -d old" "$JJ_DIR" 'jj bookmark list' 'jj bookmark set' 'jj bookmark delete'

# No equivalent — say so plainly rather than inventing one. `git add` and
# `git stash` have no jj counterpart because the working copy is already a
# tracked commit; a suggestion here would be a fabrication.
assert_reason_has "none: add explains tracking"  "git add -A" "$JJ_DIR" 'automatically'
assert_reason_has "none: stash explains why"     "git stash"  "$JJ_DIR" 'working copy'
# The specific defect #115 was filed for: stash must not be handed the generic
# six-item list. `jj file annotate` appears only in that list and in the blame
# entry, so it is a clean witness for "the fallback answered".
assert_reason_lacks "none: stash is not given the generic list" \
  "git stash" "$JJ_DIR" 'jj file annotate' 'jj git remote list'

# The subcommand is read from the clause that actually matched, so it must
# survive every prefix shape #105 taught the matcher to strip.
assert_reason_has "keyed through substitution"  'echo $(git stash)'      "$JJ_DIR" 'working copy'
assert_reason_has "keyed through subshell"      '( git stash )'          "$JJ_DIR" 'working copy'
assert_reason_has "keyed through assignment"    'GIT_X=1 git stash'      "$JJ_DIR" 'working copy'
assert_reason_has "keyed through keyword"       'if git stash; then echo ok; fi' "$JJ_DIR" 'working copy'
assert_reason_has "keyed in a later clause"     'jj git fetch && git stash' "$JJ_DIR" 'working copy'

# Unmapped and unparseable subcommands fall back to the generic list rather
# than guessing. `git -C dir status` puts a flag where the subcommand goes;
# resolving it needs argument parsing, which is exactly what this file refuses
# to do, so the fallback is the correct answer and not a bug.
# Named against the whole generic list, not just one line of it: asserting only
# `jj log` would also be satisfied by the keyed answer for `log`, so the
# fallback would look reachable even if it had been deleted.
assert_reason_has "fallback: unmapped subcommand" "git notes list" "$JJ_DIR" \
  'jj log' 'jj diff' 'jj status' 'jj file annotate' 'jj git remote list' 'jj git push'
assert_reason_has "fallback: leading flag"        "git -C /tmp status" "$JJ_DIR" \
  'jj log' 'jj diff' 'jj status' 'jj file annotate' 'jj git remote list' 'jj git push'

# The internals branch advertised `ls .git/ → not needed; use jj root` while
# `ls .git` — the bare form, no trailing slash — passed straight through. The
# rule was enforced for one spelling and advertised for both.
#
# Resolved by dropping the claim, not by widening the regex. The internals
# pattern is neither clause-split nor anchored at command position, so matching
# a bare trailing `.git` would also deny `gh repo clone …/y.git`; the wall is a
# guardrail against habit, not a sandbox, and a false positive costs more here
# than the gap does.
echo "=== jj repo: the internals message claims only what it enforces (#115) ==="
assert_reason_has "internals text still points at jj root" \
  "cat .git/HEAD" "$JJ_DIR" 'jj root'

# The internals pattern was UNANCHORED: `\.git[[:space:]]` fired on any command
# containing a .git-suffixed token followed by another word, and `git config` /
# `git rev-parse` fired on those names anywhere, including inside prose.
#
# That was not a theoretical cost. Code review found the hook denying
# `jj git clone <url>.git <dir>` — the exact command this file recommends for
# `git clone` — plus `gh repo clone`, which CLAUDE.md exempts by name. The first
# fix here dropped the `ls .git` claim from the message on the theory that
# enforcing it would deny clone URLs. That theory was wrong: it is the missing
# ANCHOR that denies clone URLs, not the enforcement. Anchoring `.git` as a
# whole path component does both — it stops denying URLs and starts catching the
# bare form.
#
# The two corpora below are generated from the DOMAIN — real internals access on
# one side, this repo's own daily commands on the other — never from the pattern.
# A corpus read off the regex proves only that the regex matches itself.
echo "=== jj repo: .git is matched as a path component, not a substring ==="
assert_blocked "internals: dot-git slash"        "cat .git/HEAD"          "$JJ_DIR"
assert_blocked "internals: bare dot-git"         "ls .git"                "$JJ_DIR"
assert_blocked "internals: bare dot-git, slash"  "ls .git/"               "$JJ_DIR"
assert_blocked "internals: nested path"          "cat /repo/.git/HEAD"    "$JJ_DIR"
assert_blocked "internals: quoted path"          'cat ".git/HEAD"'        "$JJ_DIR"
assert_blocked "internals: cd into it"           "cd .git && ls"          "$JJ_DIR"
assert_blocked "internals: delete it"            "rm -rf .git"            "$JJ_DIR"
assert_blocked "internals: separator after"      $'cat .git\nls'          "$JJ_DIR"

# Must-allow. Every one of these was DENIED by the unanchored pattern except the
# dotfiles; `.github/` is this repo's own CI directory and is used constantly.
echo "=== jj repo: must-allow — .git as a suffix or a longer name ==="
assert_passthrough "allow: jj git clone with .git URL" \
  "jj git clone https://github.com/o/r.git mydir" "$JJ_DIR"
assert_passthrough "allow: gh repo clone with .git URL" \
  "gh repo clone o/r.git mydir"                   "$JJ_DIR"
assert_passthrough "allow: package install from .git URL" \
  "npm i https://h/o/r.git --save"                "$JJ_DIR"
assert_passthrough "allow: cd into a .git-suffixed dir" "cd /tmp/foo.git && ls" "$JJ_DIR"
assert_passthrough "allow: .github workflows path"  "ls .github/workflows"  "$JJ_DIR"
assert_passthrough "allow: .github file read"       "cat .github/workflows/test.yml" "$JJ_DIR"
assert_passthrough "allow: .github script"          "bash .github/scripts/run-evals.sh --dry-run" "$JJ_DIR"
assert_passthrough "allow: .gitignore"              "cat .gitignore"        "$JJ_DIR"
assert_passthrough "allow: .gitattributes"          "cat .gitattributes"    "$JJ_DIR"
assert_passthrough "allow: .gitmodules"             "cat .gitmodules"       "$JJ_DIR"

# The plumbing alternatives are gone from the internals pattern entirely. They
# never added coverage — the raw-git branch returns first for any clause whose
# command is a bare `git`, so `git config` and `git rev-parse` at command
# position were always answered there (and now get keyed advice). All the
# internals copy did was fire on the NAMES appearing in prose, which made
# `-m 'replaces git rev-parse'` a deny while the byte-identical
# `-m 'replaces git status'` passed. Same shape, opposite answers.
echo "=== jj repo: plumbing names in prose behave like any other git name ==="
assert_blocked     "plumbing at command position: config"    "git config user.name x" "$JJ_DIR"
assert_blocked     "plumbing at command position: rev-parse" "git rev-parse HEAD"     "$JJ_DIR"
assert_passthrough "prose naming rev-parse in a message" \
  "jj describe -m 'replaces git rev-parse'"       "$JJ_DIR"
assert_passthrough "prose naming config in a PR body" \
  "gh pr create --body 'stop using git config here'" "$JJ_DIR"
# The pre-existing quote-blind limit, unchanged: prose naming the DIRECTORY is
# still denied, because `.git` there is a real path component as far as a
# text matcher can tell. Pinned, not fixed — fixing it needs quote tracking.
assert_blocked "boundary: prose naming the .git directory" \
  "jj describe -m 'the .git directory is internal'" "$JJ_DIR"

echo "=== non-jj repo: git is allowed ==="
assert_passthrough "git status in git root"   "git status"          "$GIT_DIR"
assert_passthrough "git status in git subdir" "git status"          "$GIT_DIR/src"
assert_passthrough "git commit in non-jj"     "git commit -m x"     "$GIT_DIR"
assert_passthrough "git config in non-jj"     "git config user.name x" "$GIT_DIR"

echo "=== drift-guard: both copies are byte-identical ==="
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

# ---- exclusion idioms: naming the directory in order to SKIP it ----
# The internals branch is quote-blind by design, but it was also intent-blind in
# one direction that cost real work: the canonical ways to EXCLUDE the git
# directory from a search all mention it, so all of them were denied. Each of
# these is the mirror image of access — the token exists so the tool stays out.

assert_passthrough "find -path … -prune excludes rather than reads" \
  'find . -path ./.git -prune -o -name "*.md" -print' "$JJ_DIR"
assert_passthrough "find -path with a glob and -prune" \
  "find . -path '*/.git' -prune -o -type f -print" "$JJ_DIR"
assert_passthrough "find -name … -prune" \
  'find . -name .git -prune -o -name "*.sh" -print' "$JJ_DIR"
assert_passthrough "grep --exclude-dir=" \
  'grep -rn "TODO" --exclude-dir=.git .' "$JJ_DIR"
assert_passthrough "grep --exclude-dir with quotes" \
  "grep -rn TODO --exclude-dir='.git' ." "$JJ_DIR"
assert_passthrough "rsync/tar-style --exclude=" \
  'tar czf out.tgz --exclude=.git .' "$JJ_DIR"
assert_passthrough "negated -path, no -prune (a filter, still an exclusion)" \
  "find . -not -path '*/.git/*' -name '*.sh'" "$JJ_DIR"
assert_passthrough "bang-negated -path" \
  "find . ! -path './.git/*' -type f" "$JJ_DIR"

# The carve-out must not become a passphrase. An exclusion token neutralises
# ITSELF and nothing else: a second mention that reads the directory still
# denies, and a bare -name without -prune is a SEARCH for it, not a skip.
assert_blocked "exclusion token does not launder a real read in the same command" \
  'grep -rn x --exclude-dir=.git . && cat .git/config' "$JJ_DIR"
assert_blocked "exclusion flag followed by a direct read" \
  'find . -path ./.git -prune -o -name "*.md" -print; ls .git/refs' "$JJ_DIR"
assert_blocked "-name without -prune is a search for the directory" \
  'find . -name .git -type d' "$JJ_DIR"
assert_blocked "plain read still denied with no exclusion present" \
  'cat .git/HEAD' "$JJ_DIR"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
