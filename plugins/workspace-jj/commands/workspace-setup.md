---
description: Configure jj workspace hooks for worktree isolation in the current project
allowed-tools: Bash(cp:*), Bash(chmod:*), Bash(mkdir:*), Bash(cat:*), Bash(jq:*), Read, Write
---

## Your Task

Configure the `WorktreeCreate` and `WorktreeRemove` hooks in the current project's `.claude/settings.local.json` so that `--worktree` uses jj workspaces instead of git worktrees.

**Why this is needed:** Claude Code doesn't pick up `WorktreeCreate`/`WorktreeRemove` hooks from plugins — they must be in project or user settings.

## Steps

1. **Find the plugin's installed scripts.** Look for the directory containing this command file — it will be something like `~/.claude/plugins/cache/muloka-claude-plugins/workspace-jj/<hash>/scripts/`. The scripts are:
   - `jj-workspace-create.sh`
   - `jj-workspace-remove.sh`

2. **Copy the scripts to a stable project location.** Copy both scripts to `.claude/scripts/` in the project root. This avoids pointing hooks at the plugin cache (which changes on every plugin update).

   ```bash
   mkdir -p .claude/scripts
   cp <plugin-scripts-dir>/jj-workspace-create.sh .claude/scripts/
   cp <plugin-scripts-dir>/jj-workspace-remove.sh .claude/scripts/
   chmod +x .claude/scripts/jj-workspace-create.sh .claude/scripts/jj-workspace-remove.sh
   ```

3. **Read the current settings** at `.claude/settings.local.json` (it may not exist yet, or may have existing content to preserve).

4. **Merge the following hooks** into the settings JSON, preserving any existing keys. Use the **absolute path** to the project's `.claude/scripts/` directory:

   ```json
   {
     "hooks": {
       "WorktreeCreate": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "<project-root>/.claude/scripts/jj-workspace-create.sh"
             }
           ]
         }
       ],
       "WorktreeRemove": [
         {
           "hooks": [
             {
               "type": "command",
               "command": "<project-root>/.claude/scripts/jj-workspace-remove.sh"
             }
           ]
         }
       ]
     }
   }
   ```

   Replace `<project-root>` with the actual absolute path to the project root.

5. **Write the updated settings** to `.claude/settings.local.json`.

6. **Confirm** by showing the user:
   - The scripts copied to `.claude/scripts/`
   - The hooks configured in `.claude/settings.local.json`
   - Remind them to restart their Claude Code session for the hooks to take effect
   - Suggest adding `.claude/scripts/` to `.gitignore` if they don't want to track the scripts in version control
