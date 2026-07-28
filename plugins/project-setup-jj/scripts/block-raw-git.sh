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
# Known-open, documented in the READMEs and pinned by pass-through assertions
# in test-block-raw-git.sh: backtick substitution, case patterns, an
# interpreter handed git as data (`bash -c 'git status'`), wrappers carrying
# their own options (`eval "git …"`, `sudo -u me git`, `timeout 5 git`), and
# spellings other than the bare word (`/usr/bin/git`, `\git`). All need
# argument parsing or quote tracking, i.e. a shell parser. The wall is a
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

has_raw_git=false
if printf '%s\n' "$command_normalized" \
   | sed -E -e 's/\$\(/;/g' -e 's/[<>]\(/;/g' \
   | tr ';&|' '\n\n\n' \
   | grep -qE "^[[:space:]]*${prefix_re}git[[:space:]]"; then
  has_raw_git=true
fi

# Check for .git/ access or git plumbing
has_git_internals=false
if echo "$command_normalized" | grep -qE '(\.git/|\.git[[:space:]]|git\s+config|git\s+rev-parse)'; then
  has_git_internals=true
fi

if [ "$has_raw_git" = true ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: Raw git commands are not allowed in jj repos. Use jj equivalents instead: git log → jj log, git diff → jj diff, git status → jj status, git blame → jj file annotate, git remote → jj git remote list, git push → jj git push. For GitHub operations, use gh CLI."
  }
}
EOF
  exit 0
fi

if [ "$has_git_internals" = true ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: Git internals access detected. This project uses jj (Jujutsu). Avoid accessing .git/ directly or using git plumbing commands. Use jj equivalents:\n- git rev-parse HEAD → jj log -r @ --no-graph -T commit_id\n- git config → jj config list / jj config set\n- ls .git/ → not needed; use jj root\n- git remote -v → jj git remote list"
  }
}
EOF
  exit 0
fi

exit 0
