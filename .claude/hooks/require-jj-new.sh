#!/usr/bin/env bash
# PreToolUse hook: Advise Claude if editing into a non-empty jj change
# Outputs an informational message — does NOT block or prompt the user

# Only fire in jj repos
jj root >/dev/null 2>&1 || exit 0

# Check if current change already has content
status=$(jj log -r @ --no-graph -T 'if(empty, "empty", "has-content")' 2>/dev/null)

if [ "$status" = "has-content" ]; then
  echo "Note: Current jj change already has content. Consider running \`jj new\` to start a fresh change if appropriate."
fi

exit 0
