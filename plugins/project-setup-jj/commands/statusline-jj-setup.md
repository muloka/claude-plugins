---
description: Add jj-aware statusline to this project
allowed-tools: Bash(jj:*), Bash(cp:*), Bash(chmod:*), Bash(mkdir:*), Bash(rm:*), Bash(rmdir:*), Bash(cat:*), Bash(jq:*), Read, Write
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Install the jj-aware statusline script and configure it in this project's **tracked** `.claude/settings.json`.

**Why tracked, and why the command is not a plain path:** a `claude -w` session runs in a jj workspace, which materialises only *tracked* files. A statusline configured in `.claude/settings.local.json` (gitignored) and pointing at a script under `.claude/scripts/` (also gitignored) is simply absent there — the statusline silently disappears in every side thread. Both halves must be tracked, and the command must resolve the script relative to whichever workspace is live.

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

### Step 3: Verify `.claude/hooks/` is tracked

The script only reaches a workspace if it is tracked. Check the project's
`.gitignore` for a `!.claude/hooks/` negation under the `.claude/*` line. If the
blanket form `.claude/` or `.claude/**` is used instead, no negation can work —
tell the user to switch to `.claude/*` (the same requirement `/project-setup`
enforces) or the statusline will keep vanishing in side threads.

### Step 4: Update `.claude/settings.json` (tracked)

Read the current `.claude/settings.json`. Deep-merge with `jq`, preserving all existing keys:

```bash
CMD='sh -c '"'"'p="${CLAUDE_PROJECT_DIR:-$(jj root --ignore-working-copy 2>/dev/null || pwd)}"; exec "$p/.claude/hooks/statusline-jj.sh"'"'"''
jq --arg c "$CMD" '.statusLine = {type:"command", command:$c}' \
  .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
```

Do **not** write an absolute `jj root` path here: this file is committed and
shared, and an absolute path is both machine-specific and pinned to the main
checkout. The command above resolves the live workspace instead — it prefers
`$CLAUDE_PROJECT_DIR` when the harness exports it, and otherwise falls back to
`jj root` from the current directory, which in a workspace is that workspace's
own root. `--ignore-working-copy` keeps a statusline redraw from snapshotting.

**Merge strategy:** If a `statusLine` key already exists, replace it. Preserve all other keys.

### Step 5: Strip any `statusLine` from `.claude/settings.local.json`

This step is **required, not cleanup.** Both files apply, and the local scope is
the more specific one — a leftover `statusLine` there overrides the tracked one.
The failure is deceptive: the statusline keeps working in the main checkout (so
the install looks successful) while every workspace stays broken.

```bash
[ -f .claude/settings.local.json ] && \
  jq 'del(.statusLine)' .claude/settings.local.json > .claude/settings.local.json.tmp && \
  mv .claude/settings.local.json.tmp .claude/settings.local.json
```

### Step 6: Confirm to user

Show:
- Statusline script copied to `.claude/hooks/statusline-jj.sh` (tracked — commit it, or workspaces will not see it)
- `statusLine` config added to `.claude/settings.json`, and removed from `.claude/settings.local.json` if present
- **Restart Claude Code** for the statusline to appear

The statusline shows: `[Model] bookmark-or-change-id description | N% ctx | $cost`
