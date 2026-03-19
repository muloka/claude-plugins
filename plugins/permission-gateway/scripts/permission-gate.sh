#!/usr/bin/env bash
set -euo pipefail

# Permission Gateway — PreToolUse hook
# Tier 1: Fast regex matching against known-safe and known-dangerous patterns
# Tier 2: Emit systemMessage for LLM evaluation of ambiguous commands
#
# Evaluation order: Deny → .local.md rules → Confirm → Approve → Tier 2 (LLM)
#
# One-way ratchet:
#   Hardcoded deny runs BEFORE .local.md. The deny tier is an immutable floor
#   that cannot be loosened by any override. This prevents a prompt injection
#   attack where a malicious file instructs Claude to write a .local.md rule
#   promoting a denied command to approve.
#
#   .local.md CAN: add new deny rules, add confirm rules, add approve rules
#                  for commands not already hardcoded-denied.
#   .local.md CANNOT: override a hardcoded deny to confirm or approve.
#
#   Precedence: hardcoded deny > project .local.md > user global .local.md > hardcoded confirm/approve
#   Tie-breaking within .local.md: deny wins at the same level
#
# Logging:
#   Every decision is logged to .claude/permission-gateway.log with timestamp,
#   decision (APPROVE/DENY/CONFIRM), and command. Review the log to promote
#   frequently-confirmed commands to auto-approve in .local.md.
#
# Note: approve/deny/ask helper functions call `exit 0` directly,
# terminating the entire script. This is intentional — the hook must
# return exactly one decision per invocation.

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Normalize: collapse newlines, trim whitespace
command_normalized=$(echo "$command" | tr '\n' ';' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# --- Logging and helper functions ---

cwd=$(echo "$input" | jq -r '.cwd // ""')

# Log every decision for rule self-tuning
# Format: 2026-03-19T04:15:23Z APPROVE npm test
#         2026-03-19T04:15:24Z DENY rm -rf /
#         2026-03-19T04:15:25Z CONFIRM docker run ubuntu
# Project log if cwd/.claude exists, otherwise user-global log
log_decision() {
  local decision="$1"
  local log_file=""
  if [ -n "$cwd" ] && [ -d "$cwd/.claude" ]; then
    log_file="$cwd/.claude/permission-gateway.log"
  elif [ -d "$HOME/.claude" ]; then
    log_file="$HOME/.claude/permission-gateway.log"
  fi
  if [ -n "$log_file" ]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $decision $command" >> "$log_file" 2>/dev/null || true
  fi
}

# Each helper logs, then exits the script immediately with the decision.

approve() {
  log_decision "APPROVE"
  exit 0
}

deny() {
  local reason="$1"
  log_decision "DENY"
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: $reason"
  }
}
EOF
  exit 0
}

ask() {
  local reason="${1:-Permission gateway: command did not match any known-safe or known-dangerous pattern. Requesting human approval.}"
  log_decision "CONFIRM"
  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "$reason"
  }
}
EOF
  exit 0
}

# --- .local.md rule loading ---
# .local.md rules take precedence over hardcoded defaults (project > global > defaults).

# Parse YAML frontmatter from a .local.md file
# Extracts patterns under rules.approve/rules.deny/rules.ask sections
# Returns lines in format: "approve:pattern" or "deny:pattern" or "ask:pattern"
parse_local_md() {
  local file="$1"
  [ -f "$file" ] || return 0

  local in_frontmatter=false
  local in_rules=false
  local current_section=""

  while IFS= read -r line; do
    # Detect frontmatter boundaries
    if [ "$line" = "---" ]; then
      if [ "$in_frontmatter" = true ]; then
        break  # End of frontmatter
      else
        in_frontmatter=true
        continue
      fi
    fi

    [ "$in_frontmatter" = true ] || continue

    # Detect rules: top-level key
    if echo "$line" | grep -qE '^rules:'; then
      in_rules=true
      continue
    fi

    # If we hit another top-level key, stop parsing rules
    if [ "$in_rules" = true ] && echo "$line" | grep -qE '^[a-z]'; then
      in_rules=false
      current_section=""
      continue
    fi

    [ "$in_rules" = true ] || continue

    # Detect section headers (approve:/deny:/ask:) under rules:
    if echo "$line" | grep -qE '^\s+(approve|deny|ask):'; then
      current_section=$(echo "$line" | sed -E 's/.*(approve|deny|ask).*/\1/')
      continue
    fi

    # Extract pattern from "    - \"pattern\"" lines
    if [ -n "$current_section" ] && echo "$line" | grep -qE '^\s+-\s+"'; then
      local pattern
      pattern=$(echo "$line" | sed 's/.*"\(.*\)".*/\1/')
      echo "${current_section}:${pattern}"
    fi
  done < "$file"
}

# Load rules: project first, then user global
local_rules=""
if [ -n "$cwd" ] && [ -f "$cwd/.claude/permission-gateway.local.md" ]; then
  local_rules=$(parse_local_md "$cwd/.claude/permission-gateway.local.md")
fi

global_rules=""
if [ -f "$HOME/.claude/permission-gateway.local.md" ]; then
  global_rules=$(parse_local_md "$HOME/.claude/permission-gateway.local.md")
fi

# Check .local.md rules against command
# Note: approve/deny/ask helpers exit the script directly (see helpers above).
# The `return 1` at the end only fires when no pattern matched.
check_local_rules() {
  local rules="$1"
  [ -n "$rules" ] || return 1

  # Check deny rules first (deny wins at same level)
  while IFS= read -r rule; do
    local decision="${rule%%:*}"
    local pattern="${rule#*:}"
    [ "$decision" = "deny" ] || continue
    # Convert glob-style * to regex .*
    local regex=$(echo "$pattern" | sed 's/\*/.*/')
    if echo "$command_normalized" | grep -qE "(^|[;&|]\s*)${regex}"; then
      deny "Blocked by .local.md rule: $pattern"
    fi
  done <<< "$rules"

  # Check approve rules
  while IFS= read -r rule; do
    local decision="${rule%%:*}"
    local pattern="${rule#*:}"
    [ "$decision" = "approve" ] || continue
    local regex=$(echo "$pattern" | sed 's/\*/.*/')
    if echo "$command_normalized" | grep -qE "(^|[;&|]\s*)${regex}"; then
      approve
    fi
  done <<< "$rules"

  # Check ask rules
  while IFS= read -r rule; do
    local decision="${rule%%:*}"
    local pattern="${rule#*:}"
    [ "$decision" = "ask" ] || continue
    local regex=$(echo "$pattern" | sed 's/\*/.*/')
    if echo "$command_normalized" | grep -qE "(^|[;&|]\s*)${regex}"; then
      ask "Matched .local.md ask rule: $pattern"
    fi
  done <<< "$rules"

  return 1  # No match
}

# --- Tier 1: Dangerous patterns (check first — immutable floor) ---
# These use (^|[;&|]\s*) anchors to catch commands anywhere in a chain.

# Destructive filesystem
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)rm\s+-(r|f|rf|fr)'; then
  # Allow rm -rf on safe paths (build dirs, node_modules, etc.)
  if ! echo "$command_normalized" | grep -qE 'rm\s+-(rf|fr)\s+(\.\/)?(\./?)?(dist|build|out|target|node_modules|\.cache|__pycache__|\.pytest_cache|coverage|tmp)\b'; then
    deny "Recursive/force deletion outside of safe build directories."
  fi
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)chmod\s+-R\s+777'; then
  deny "Recursive chmod 777 is a security risk."
fi

# Privilege escalation
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(sudo|doas)\s'; then
  deny "Privilege escalation commands require manual approval."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)su\s+-'; then
  deny "User switching requires manual approval."
fi

# Dangerous VCS
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)git\s+push\s+.*--force'; then
  deny "Force push can destroy remote history."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)git\s+reset\s+--hard'; then
  deny "Hard reset discards uncommitted work."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)jj\s+git\s+push\s+.*--force'; then
  deny "Force push can destroy remote history."
fi

# Disk-level writes
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)dd\s'; then
  deny "dd performs disk-level writes and can destroy data."
fi

# Destructive file operations
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(truncate|shred)\s'; then
  deny "Destructive file operation — data cannot be recovered."
fi

# Process nuking
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(kill\s+-9|killall)\s'; then
  deny "Process nuking can cause data loss and corruption."
fi

# Arbitrary execution
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)eval\s'; then
  deny "eval executes arbitrary code — too risky for auto-approval."
fi

# Container escape risk
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)docker\s+run\s.*--privileged'; then
  deny "Privileged containers can escape to the host system."
fi

# Filesystem-level operations
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(mkfs[\s.]|mount\s|umount\s)'; then
  deny "Filesystem-level operation — can destroy volumes or corrupt mounts."
fi

# Firewall mutations
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(iptables|ufw)\s'; then
  deny "Firewall mutation — can lock out network access."
fi

# Cron deletion
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)crontab\s+-r'; then
  deny "crontab -r deletes all scheduled jobs."
fi

# Service disruption
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)systemctl\s+(stop|disable)\s'; then
  deny "Stopping/disabling services can cause system disruption."
fi

# Network probing
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(nc|netcat|nmap)\s'; then
  deny "Network probing tools — not appropriate for auto-approval."
fi

# Ownership changes
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)chown\s'; then
  deny "Ownership changes can break file access."
fi

# System-level package mutation — moved to confirm (not deny) because
# Claude legitimately needs build deps (e.g., apt install libssl-dev)


# Scheduled execution
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)crontab\s+-e'; then
  deny "crontab -e creates scheduled execution — too risky for auto-approval."
fi

# Network exfiltration patterns
if echo "$command_normalized" | grep -qE 'curl\s.*\|\s*(sh|bash|zsh)'; then
  deny "Piping remote content to a shell is a security risk."
fi

if echo "$command_normalized" | grep -qE 'wget\s.*&&\s*(sh|bash|zsh)'; then
  deny "Downloading and executing remote scripts is a security risk."
fi

# --- .local.md rules (runs after hardcoded deny — can only tighten or add, not loosen) ---
# Project rules first (most specific wins)
check_local_rules "$local_rules" || true
# Then user global rules
check_local_rules "$global_rules" || true

# --- Tier 1: Irreversible public-facing actions (ask — require human confirmation) ---

# Publishing to registries
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)npm\s+publish'; then
  ask "npm publish is irreversible — requires human confirmation."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)cargo\s+publish'; then
  ask "cargo publish is irreversible — requires human confirmation."
fi

# Pushing to remote (non-force, already not in safe list)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)jj\s+git\s+push\b'; then
  ask "jj git push affects shared state — requires human confirmation."
fi

# Remote access
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(ssh|scp)\s'; then
  ask "Remote access command — requires human confirmation."
fi

# File moves (can clobber destination)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)mv\s'; then
  ask "mv can overwrite files — requires human confirmation."
fi

# In-place sed (modifies files directly)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)sed\s+-i'; then
  ask "sed -i modifies files in-place — requires human confirmation."
fi

# Docker build (resource-intensive, may push layers)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)docker\s+build'; then
  ask "docker build — requires human confirmation."
fi

# Docker run (non-privileged — privileged already denied above)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)docker\s+run\s'; then
  ask "docker run executes arbitrary images — requires human confirmation."
fi

# Docker compose
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)docker\s+compose\s+up'; then
  ask "docker compose up spins up services — requires human confirmation."
fi

# Package installation (modifies lockfiles/environment)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)npm\s+(install|add)\b'; then
  ask "npm install modifies package.json/lockfile — requires human confirmation."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(yarn|pnpm)\s+add\b'; then
  ask "Package add modifies lockfile — requires human confirmation."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)cargo\s+add\b'; then
  ask "cargo add modifies Cargo.toml — requires human confirmation."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)pip\s+install\b'; then
  ask "pip install modifies environment — requires human confirmation."
fi

# System-level package installation
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(apt|apt-get|brew)\s+install'; then
  ask "System package install — requires human confirmation."
fi

# git push (non-force — force already denied above)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)git\s+push\b'; then
  ask "git push affects shared state — requires human confirmation."
fi

# rm single files (non-recursive, outside safe dirs)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)rm\s+[^-]'; then
  ask "rm deletes files — requires human confirmation."
fi

# Inline arbitrary execution
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)python\s+-c\s'; then
  ask "python -c executes arbitrary code — requires human confirmation."
fi

if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)node\s+-e\s'; then
  ask "node -e executes arbitrary code — requires human confirmation."
fi

# git clone (post-checkout hooks can execute arbitrary code)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)git\s+clone\s'; then
  ask "git clone can trigger post-checkout hooks — requires human confirmation."
fi

# Source/dot — executes scripts in current shell context
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(source|\.)\s'; then
  ask "source executes scripts in current shell — requires human confirmation."
fi

# Irreversible GitHub actions
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)gh\s+(release\s+create|pr\s+merge)'; then
  ask "Irreversible GitHub action — requires human confirmation."
fi

# Indirect execution via script files (eval with extra steps)
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)(bash|sh|zsh)\s+[^-]'; then
  ask "Executing a script file — requires human confirmation."
fi

# xargs — amplifies whatever follows it, can bypass safe-rm allowlist
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*|\|)\s*xargs\s'; then
  ask "xargs amplifies commands — requires human confirmation."
fi

# find -exec / find -delete — destructive when combined with modifying actions
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)find\s.*(-exec|-delete)'; then
  ask "find with -exec/-delete can be destructive — requires human confirmation."
fi

# Redirect clobber — > (not >>) to paths outside project working directory
# ./relative and bare filenames are fine; absolute paths and ~/ deserve confirmation
if echo "$command_normalized" | grep -qE '[^>]>\s*[^>]'; then
  # Extract the redirect target (rough — first > not part of >>)
  redirect_target=$(echo "$command_normalized" | sed -E 's/.*[^>]>\s*([^>;&|]+).*/\1/' | sed 's/^[[:space:]]*//')
  # Flag absolute paths and home-relative paths (not ./relative or bare filenames)
  if echo "$redirect_target" | grep -qE '^(/|~)'; then
    ask "Redirect clobber to path outside project directory — requires human confirmation."
  fi
fi

# Backgrounding — processes that outlive the session
if echo "$command_normalized" | grep -qE '(^|[;&|]\s*)nohup\s'; then
  ask "nohup spawns processes that outlive the session — requires human confirmation."
fi


# --- Tier 1: Safe patterns ---
# Safe read-only commands (anchored to start — first command in chain)
if echo "$command_normalized" | grep -qE '^(ls|cat|head|tail|wc|jq|echo|pwd|which|whoami|date|file|stat|diff|sort|uniq|tr|cut|tee|less|more|env|printenv|type|grep|rg|find|fd|tree|awk|sed|hexdump|hex|xxd|od)\b'; then
  approve
fi

# Non-destructive file operations
if echo "$command_normalized" | grep -qE '^(mkdir|cp|touch|ln)\b'; then
  approve
fi

# toko CLI (user's own tool — all operations safe)
if echo "$command_normalized" | grep -qE '^toko\b'; then
  approve
fi

# git read-only (even in jj-first repos, git reads may surface)
if echo "$command_normalized" | grep -qE '^git\s+(log|status|diff|show|branch|tag|remote|stash\s+list)\b'; then
  approve
fi

# Safe dev tools
if echo "$command_normalized" | grep -qE '^npm\s+(test|run\s+(test|lint|build|dev|start)|ci|ls|outdated|audit)\b'; then
  approve
fi

if echo "$command_normalized" | grep -qE '^(npx|yarn|pnpm)\s+(test|lint|build|dev|start)\b'; then
  approve
fi

if echo "$command_normalized" | grep -qE '^cargo\s+(test|build|check|clippy|fmt|doc|bench)\b'; then
  approve
fi

if echo "$command_normalized" | grep -qE '^(pytest|python\s+-m\s+pytest|mypy|ruff|black|isort)\b'; then
  approve
fi

if echo "$command_normalized" | grep -qE '^(make|cmake|tsc|eslint|prettier)\b'; then
  approve
fi

if echo "$command_normalized" | grep -qE '^(go\s+(test|build|vet|fmt)|rustfmt)\b'; then
  approve
fi

# Safe VCS (jj read-only)
if echo "$command_normalized" | grep -qE '^jj\s+(log|status|diff|show|file|config\s+list|root|workspace\s+list|op\s+log)\b'; then
  approve
fi

# Safe jj write operations (local only, no push)
if echo "$command_normalized" | grep -qE '^jj\s+(new|describe|commit|edit|squash|abandon|undo|rebase|resolve|bookmark)\b'; then
  approve
fi

# Safe rm -rf on build directories (passed through dangerous check above)
if echo "$command_normalized" | grep -qE '^rm\s+-(rf|fr)\s+(\.\/)?(\./?)?(dist|build|out|target|node_modules|\.cache|__pycache__|\.pytest_cache|coverage|tmp)\b'; then
  approve
fi

# --- Tier 2: No Tier 1 match — emit systemMessage for LLM evaluation ---
# Read the prompt template and substitute the command
PROMPT_DIR="$(cd "$(dirname "$0")/../prompts" && pwd)"
if [ -f "$PROMPT_DIR/permission-evaluate.md" ]; then
  # Escape the command for JSON embedding
  escaped_command=$(echo "$command" | jq -Rs .)
  prompt_template=$(cat "$PROMPT_DIR/permission-evaluate.md")
  prompt_with_command=$(echo "$prompt_template" | sed "s|{{COMMAND}}|$command|g")
  escaped_prompt=$(echo "$prompt_with_command" | jq -Rs .)

  cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Permission gateway Tier 2: command requires evaluation. See system message for context."
  },
  "systemMessage": $escaped_prompt
}
EOF
  exit 0
fi

# Fallback if prompt template is missing
ask "Permission gateway: command did not match any known pattern and prompt template is missing."
