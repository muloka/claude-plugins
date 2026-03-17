#!/usr/bin/env bash
# PreToolUse hook: Block raw git commands in jj plugins
# Allows: jj git *, gh *, and any non-git commands
# Blocks: git * (bare git commands, not jj git subcommands)

input=$(cat)
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

if [ "$has_raw_git" = true ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: Raw git commands are not allowed in jj plugins. Use jj equivalents instead: git log → jj log, git diff → jj diff, git status → jj status, git blame → jj file annotate, git remote → jj git remotes list, git push → jj git push. For GitHub operations, use gh CLI."
  }
}
EOF
  exit 0
fi

exit 0
