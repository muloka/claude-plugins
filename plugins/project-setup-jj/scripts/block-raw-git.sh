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

# Check for bare "git " commands (not preceded by "jj ")
has_raw_git=false
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)git\s'; then
  if ! echo "$command_normalized" | grep -qE '(^|[;&|]\s*)jj\s+git\s'; then
    has_raw_git=true
  fi
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
