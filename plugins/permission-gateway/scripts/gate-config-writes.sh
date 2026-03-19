#!/usr/bin/env bash

# Gate the gate — prevent silent modification of permission-gateway files
# and hook registration settings.
#
# Protected paths:
#   *permission-gate*     — the evaluation engine itself
#   *permission-gateway*  — config files (.local.md, plugin.json, etc.)
#   .claude/settings*     — hook registration (removing hooks disables the gate)
#   settings.local.json   — project-level hook config
#
# Fail-closed: if jq fails or input is malformed, default to "ask" rather
# than silently passing through. A crashed gate should not be a bypass.

# Trap any error and fail-closed with "ask"
trap 'cat <<EREOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Permission gateway: gate-config-writes encountered an error and is failing closed. Human approval required."
  }
}
EREOF
exit 0' ERR

set -euo pipefail

input=$(cat)
file_path=$(echo "$input" | jq -r '.tool_input.file_path // ""')

# Check if the write target is a protected file
if echo "$file_path" | grep -qiE '(permission-gate|\.claude/settings|\.claude-plugin/)'; then
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Writing to permission-gateway or hook configuration — requires human confirmation. This file controls which commands are auto-approved, blocked, or which hooks are active."
  }
}
EOF
  exit 0
fi

# Explicit pass-through — silent exit 0 with no output means "no opinion"
# (verified: Claude Code treats empty stdout + exit 0 as pass-through)
exit 0
