#!/usr/bin/env bash

# Gate the gate — prevent silent modification of permission-gateway files
# and hook registration settings.
#
# Protected paths:
#   *permission-gate*     — the evaluation engine itself
#   *permission-gateway*  — config files (.local.md, plugin.json, etc.)
#   .claude/settings*     — hook registration (removing hooks disables the gate)
#   settings.local.json   — project-level hook config
#   .claude/hooks/        — the hook SCRIPTS themselves
#   .claude/scripts/      — where the installer used to put them (LEGACY_DST in
#                           project-setup-install.sh); old projects still
#                           register from there, so it stays a live bypass
#                           until they migrate
#
# The two .claude/ script directories were added after the gap they left was
# measured. Gating the registration but not the script it points at protects
# the lock and leaves the door: this guard exists because "removing hooks
# disables the gate", and rewriting block-raw-git.sh in place disables it just
# as completely with nothing asked. #97 makes that worse by tracking
# .claude/hooks/, so a neutered wall would reach every collaborator through a
# merged pull request rather than dying with one working copy.
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

# Check if the write target is a protected file.
#
# The match is run OUTSIDE an `if` condition, and its three outcomes are handled
# separately, because `set -e` and the ERR trap above are both exempt for a
# command used as an if/while condition. Written as
# `if ... | grep -qiE ...; then`, a grep that FAILED (bad regex after an edit,
# grep missing from PATH, a locale/encoding error) is indistinguishable from
# "no match": the trap never fires, control falls through to the closing
# `exit 0`, and the gate PASSES THROUGH. Measured — that is fail-OPEN on the one
# line that decides ask-vs-passthrough, in a script whose header promises the
# opposite. grep's contract makes the distinction available: 0 = match,
# 1 = no match, anything else = error.
# `|| match_rc=$?`, not a bare call: the ERR trap fires on ANY non-zero simple
# command, independent of `set -e`, and is exempt only for a command in an
# if/while test or on the left of `&&`/`||`. Run bare, grep's benign exit 1
# ("no match") would trip the trap and ask about every unprotected path —
# measured while writing this. The `||` form keeps exit 1 quiet while still
# letting exit 2 reach the check below.
match_rc=0
printf '%s' "$file_path" \
  | grep -qiE '(permission-gate|\.claude/settings|\.claude/hooks/|\.claude/scripts/|\.claude-plugin/)' \
  || match_rc=$?

if [ "$match_rc" -gt 1 ]; then
  # grep itself failed. Never silently allow — a broken matcher must not become
  # a bypass, which is the whole premise of gating config writes.
  cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Permission gateway: gate-config-writes could not evaluate the target path (matcher error) and is failing closed. Human approval required."
  }
}
EOF
  exit 0
fi

if [ "$match_rc" -eq 0 ]; then
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
