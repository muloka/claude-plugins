---
description: Install machine-level jj query helpers (jjctx, jjstack, jjconflicts, jjcheckpoint) for agents
allowed-tools: Bash(jj:*), Bash(bash:*), Bash(cat:*), Bash(grep:*), Read
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Install the read-only jj query helpers **machine-wide** (not per-project). This writes to three files under the user's home directory, so you MUST get consent first.

### Step 1: Explain and get consent

Tell the user this will:
- copy the helper script to `~/.config/jj-agent-helpers/jj-agent-helpers.sh`
- add a `source` line to `~/.zshrc` (fenced, removable)
- add a one-line catalog block to `~/.claude/CLAUDE.md`
- add four `Bash(jj…:*)` entries to `permissions.allow` in `~/.claude/settings.json`

Ask for explicit confirmation before proceeding. If the user declines, print the four changes they could make by hand (the `source` line and the fence markers are in `${CLAUDE_PLUGIN_ROOT}/scripts/agent-helpers-install.sh`) and stop without changing anything.

### Step 2: Run the installer

On confirmation:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-helpers-install.sh" install
```
The script is idempotent — re-running it will not create duplicates.

### Step 3: Report and remind

Report what changed (the four targets above). Then, prominently:

> **Restart Claude Code (or start a new session) for the helpers to take effect.** They become callable only after the next session regenerates its shell snapshot; the permission allowlist also applies from the next session.

Warn if any of the names `jjctx`, `jjstack`, `jjconflicts`, `jjcheckpoint`, or `_jjq` were already defined in the user's shell (the source line will shadow them). Remove with `/agent-helpers-remove`.
