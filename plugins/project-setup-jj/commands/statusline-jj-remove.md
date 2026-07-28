---
description: Remove jj statusline from this project
allowed-tools: Bash(jj:*), Bash(rm:*), Bash(rmdir:*), Bash(cat:*), Bash(jq:*), Read, Write
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Remove the jj statusline script and configuration from this project.

### Step 1: Detect context

1. Determine the project root using `jj root`. If it fails, tell the user this command requires a jj repository and stop.

### Step 2: Remove statusline script

Delete from **both** locations. The statusline now lives in `.claude/hooks/`, but a
project set up before that move still has it in `.claude/scripts/` — removing only
the new path would leave that copy behind and the uninstall would silently not
uninstall anything:

```bash
rm -f "$(jj root)/.claude/hooks/statusline-jj.sh"
rm -f "$(jj root)/.claude/scripts/statusline-jj.sh"
```

Then drop the legacy directory if it is now empty. Use `rmdir`, never `rm -rf`: it
refuses a non-empty directory, so a script the user keeps there is never destroyed:

```bash
rmdir "$(jj root)/.claude/scripts" 2>/dev/null || true
```

### Step 3: Remove statusLine from settings

Read `.claude/settings.local.json`. If it has a `statusLine` key, remove it using `jq`:

```bash
jq 'del(.statusLine)' .claude/settings.local.json > .claude/settings.local.json.tmp && mv .claude/settings.local.json.tmp .claude/settings.local.json
```

If no `statusLine` key exists, skip — nothing to remove.

### Step 4: Confirm to user

Show:
- Statusline script removed (or was not present)
- `statusLine` config removed from settings (or was not present)
- **Restart Claude Code** for the change to take effect
