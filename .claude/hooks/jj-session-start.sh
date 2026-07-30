#!/usr/bin/env bash
# SessionStart hook: Show jj context and workflow reminder
# Outputs JSON with additionalContext for Claude Code

set -euo pipefail

# Exit silently if not in a jj repo
if ! jj root >/dev/null 2>&1; then
  exit 0
fi

# Gather jj context
current_change=$(jj log -r @ --no-graph -T 'json(self) ++ "\n"' 2>/dev/null || echo "(unable to read current change)")
working_status=$(jj status 2>/dev/null || echo "(unable to read status)")
repo_config=$(jj config list -T 'json(self) ++ "\n"' 2>/dev/null || echo "(unable to read config)")

# Escape string for JSON embedding
escape_for_json() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

context="== jj Session Context ==

Current change:
${current_change}

Working copy status:
${working_status}

Repository config (JSON):
${repo_config}

== jj Workflow Reminder ==
- Use \`jj new\` to start a fresh change before making edits
- Use \`jj describe -m \"...\"\` to set intent on the current change
- Use \`jj diff\` to review working copy changes
- Never use raw git commands — use jj equivalents"

escaped_context=$(escape_for_json "$context")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped_context}"
  }
}
EOF

exit 0
