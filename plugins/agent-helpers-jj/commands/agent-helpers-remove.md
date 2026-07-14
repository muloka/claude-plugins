---
description: Remove the machine-level jj query helpers installed by agent-helpers-jj
allowed-tools: Bash(jj:*), Bash(bash:*), Read
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Reverse the machine-level install performed by `/agent-helpers-setup`.

### Step 1: Run the uninstaller

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-helpers-install.sh" remove
```
This is idempotent and safe to run even if nothing is installed. It removes the fenced blocks from `~/.zshrc` and `~/.claude/CLAUDE.md`, filters the four helper values out of `~/.claude/settings.json`, and deletes `~/.config/jj-agent-helpers/jj-agent-helpers.sh`.

### Step 2: Report and remind

Report the four reversals. Then remind:

> **Restart Claude Code (or start a new session)** so the removed functions and allowlist entries stop applying.
