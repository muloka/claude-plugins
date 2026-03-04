#!/usr/bin/env bash
# PreToolUse hook: Warn if editing into a non-empty jj change
# Reminds to run `jj new` before making edits to keep changes isolated

# Only fire in jj repos
jj root >/dev/null 2>&1 || exit 0

# Check if current change already has content
status=$(jj log -r @ --no-graph -T 'if(empty, "empty", "has-content")' 2>/dev/null)

if [ "$status" = "has-content" ]; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Current jj change already has content. Consider running `jj new` first to start a fresh change, keeping your work isolated and easy to undo.\n\nWorkflow:\n1. `jj new` — start fresh change\n2. `jj describe -m \"...\"` — set intent\n3. Make your edits"
  }
}
EOF
  exit 0
fi

exit 0
