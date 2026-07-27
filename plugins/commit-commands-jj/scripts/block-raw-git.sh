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
has_raw_git=false
if printf '%s\n' "$command_normalized" | tr ';&|' '\n\n\n' \
   | grep -qE '^[[:space:]]*git[[:space:]]'; then
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
