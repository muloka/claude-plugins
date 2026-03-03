---
description: Bootstrap jj (Jujutsu) workflow enforcement for this project
allowed-tools: Bash(jj:*), Bash(cp:*), Bash(chmod:*), Bash(mkdir:*), Bash(cat:*), Bash(jq:*), Bash(ls:*), Bash(dirname:*), Bash(realpath:*), Read, Write
---

## Your Task

Bootstrap jj (Jujutsu) workflow enforcement for the current project. This sets up a SessionStart hook, hookify rules, permissions, and CLAUDE.md instructions so that every Claude Code session in this project uses jj properly.

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Steps

### Step 1: Detect context

1. Verify this is a jj repo by running `jj root`. If it fails, tell the user this command requires a jj repository and stop.
2. Find the plugin's templates/scripts directory. Look for the directory containing this command file — it will be something like `~/.claude/plugins/cache/muloka-claude-plugins/project-setup-jj/<hash>/`. The templates are in `templates/` and scripts in `scripts/` relative to the plugin root.
3. Determine the project root using `jj root`.
4. Ensure `.claude/` and `.claude/scripts/` directories exist in the project root:
   ```bash
   mkdir -p "$(jj root)/.claude/scripts"
   ```

### Step 2: Copy SessionStart hook script

Copy `jj-session-start.sh` from the plugin's `scripts/` directory to the project's `.claude/scripts/`:

```bash
cp <plugin-scripts-dir>/jj-session-start.sh "$(jj root)/.claude/scripts/"
chmod +x "$(jj root)/.claude/scripts/jj-session-start.sh"
```

### Step 3: Update `.claude/settings.local.json`

Read the current `.claude/settings.local.json` (may not exist). Deep-merge the following configuration using `jq`, preserving all existing keys and deduplicating entries:

**SessionStart hook:**
```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "<project-root>/.claude/scripts/jj-session-start.sh",
            "async": false
          }
        ]
      }
    ]
  }
}
```

**Permissions:**
```json
{
  "permissions": {
    "allow": [
      "Bash(jj status*)", "Bash(jj diff*)", "Bash(jj log*)",
      "Bash(jj new*)", "Bash(jj commit*)", "Bash(jj describe*)",
      "Bash(jj bookmark*)", "Bash(jj git push*)", "Bash(jj git fetch*)",
      "Bash(jj rebase*)", "Bash(jj squash*)", "Bash(jj edit*)",
      "Bash(jj abandon*)", "Bash(jj undo*)", "Bash(jj op log*)",
      "Bash(jj resolve*)", "Bash(jj root*)", "Bash(jj file*)",
      "Bash(jj split*)", "Bash(jj config*)", "Bash(jj git remote*)",
      "Bash(gh *)"
    ],
    "deny": ["Bash(git *)"]
  }
}
```

Replace `<project-root>` with the actual absolute path from `jj root`.

**Merge strategy:** Use `jq` to deep-merge. For array fields (`allow`, `deny`, hook arrays), concatenate and deduplicate. For object fields, merge recursively. Preserve any existing settings not related to jj.

### Step 4: Create hookify rules

Copy the 3 hookify rule templates from the plugin's `templates/` directory to `.claude/` in the project root:

- `hookify.warn-raw-git.local.md`
- `hookify.require-jj-workflow.local.md`
- `hookify.warn-git-internals.local.md`

For each file: if an identical file already exists, skip it. If a different version exists, overwrite it (the plugin version is canonical).

### Step 5: Create or update CLAUDE.md

Read the CLAUDE.md template from the plugin's `templates/CLAUDE.md.template`.

Then handle three cases:

1. **No CLAUDE.md exists:** Create it from the template.
2. **CLAUDE.md exists with `<!-- jj-project-setup:start -->` marker:** Replace the section between `<!-- jj-project-setup:start -->` and `<!-- jj-project-setup:end -->` (inclusive) with the template content.
3. **CLAUDE.md exists without the marker:** Prepend the template content followed by a blank line, preserving all existing content.

The CLAUDE.md file is at the project root (from `jj root`).

### Step 6: Confirm to user

Show a summary of what was set up:

- SessionStart hook script copied to `.claude/scripts/jj-session-start.sh`
- Settings updated in `.claude/settings.local.json` (SessionStart hook + permissions)
- Hookify rules created in `.claude/` (list the 3 files)
- CLAUDE.md created/updated with jj workflow instructions

Remind the user to:
- **Restart Claude Code** for the SessionStart hook to take effect
- Optionally run `/workspace-setup` if they want worktree isolation via jj workspaces
- Optionally add `.claude/scripts/` and `.claude/*.local.md` to their ignore patterns if they don't want to track these in version control
