---
description: Add jj-aware statusline to this project
allowed-tools: Bash(jj:*), Bash(cp:*), Bash(chmod:*), Bash(mkdir:*), Bash(rm:*), Bash(rmdir:*), Bash(cat:*), Bash(jq:*), Read, Write
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Install the jj-aware statusline script and configure it in this project's `.claude/settings.local.json`.

### Step 1: Detect context

1. Verify this is a jj repo by running `jj root`. If it fails, tell the user this command requires a jj repository and stop.
2. Find the plugin's scripts directory. Look for the directory containing this command file — it will be something like `~/.claude/plugins/cache/muloka-claude-plugins/project-setup-jj/<hash>/`. The scripts are in `scripts/` relative to the plugin root.
3. Determine the project root using `jj root`.
4. Ensure `.claude/hooks/` exists in the project root:
   ```bash
   mkdir -p "$(jj root)/.claude/hooks"
   ```

### Step 2: Copy statusline script

Copy `statusline-jj.sh` from the plugin's `scripts/` directory to the project's `.claude/hooks/`:

```bash
cp <plugin-scripts-dir>/statusline-jj.sh "$(jj root)/.claude/hooks/"
chmod +x "$(jj root)/.claude/hooks/statusline-jj.sh"
```

If a copy is left over at the old `.claude/scripts/statusline-jj.sh`, remove it so only one copy exists:

```bash
rm -f "$(jj root)/.claude/scripts/statusline-jj.sh"
rmdir "$(jj root)/.claude/scripts" 2>/dev/null || true
```

`rmdir` refuses a non-empty directory, so this only cleans up when nothing else remains there.

### Step 3: Update `.claude/settings.local.json`

Read the current `.claude/settings.local.json` (may not exist). Deep-merge the following configuration using `jq`, preserving all existing keys:

```json
{
  "statusLine": {
    "type": "command",
    "command": "<project-root>/.claude/hooks/statusline-jj.sh"
  }
}
```

Replace `<project-root>` with the actual absolute path from `jj root`.

**Merge strategy:** If a `statusLine` key already exists, replace it. Preserve all other keys.

### Step 4: Confirm to user

Show:
- Statusline script copied to `.claude/hooks/statusline-jj.sh`
- `statusLine` config added to `.claude/settings.local.json`
- **Restart Claude Code** for the statusline to appear

The statusline shows: `[Model] bookmark-or-change-id description | N% ctx | $cost`
