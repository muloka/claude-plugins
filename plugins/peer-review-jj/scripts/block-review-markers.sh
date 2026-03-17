#!/usr/bin/env bash
# PreToolUse hook: Warn if REVIEW(peer): markers found in code being committed
# Safety backstop for future annotation features

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only check jj commit/squash operations
if echo "$command" | grep -qE '(jj\s+(commit|squash))'; then
  # Check staged changes for review markers
  if jj diff 2>/dev/null | grep -q 'REVIEW(peer):'; then
    cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: Found REVIEW(peer): markers in code being committed. These are review annotations that should not land in the codebase. Remove them before committing."
  }
}
EOF
    exit 0
  fi
fi

exit 0
