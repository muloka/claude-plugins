#!/usr/bin/env bash
# PreToolUse hook: Block commits containing REVIEW(peer): markers
# Safety backstop for future annotation features

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only check jj commit/squash operations
if echo "$command" | grep -qE '(jj\s+(commit|squash))'; then
  # Check staged changes for review markers (exclude hook scripts, docs, and test files that reference the pattern)
  if jj diff 2>/dev/null | grep -v -E '(block-review-markers|\.md:)' | grep -q 'REVIEW(peer):'; then
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
