#!/usr/bin/env bash
set -euo pipefail

# Gate the gate — prevent silent modification of permission-gateway config files.
# If Claude is tricked by prompt injection into writing a .local.md rule that
# loosens deny→approve, this hook catches it before the file is modified.

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# Check if the write target is a permission-gateway config file
if echo "$file_path" | grep -qiE 'permission-gateway'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Writing to permission-gateway configuration — requires human confirmation. This file controls which commands are auto-approved or blocked."
  }
}
EOF
  exit 0
fi

exit 0
