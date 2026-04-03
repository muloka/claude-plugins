# Setup Consolidation Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fold `/workspace-setup` into `/project-setup` so one command installs all jj hooks including workspace isolation.

**Architecture:** Copy workspace scripts into project-setup-jj's scripts directory, update the project-setup command to install them, update the CLAUDE.md template with the fan-flames override row, delete the standalone workspace-setup command.

**Tech Stack:** Markdown (command file), shell scripts, JSON (settings), jq (merge)

**Spec:** `docs/specs/2026-04-03-setup-consolidation-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `plugins/project-setup-jj/scripts/jj-workspace-create.sh` | Create (copy) | WorktreeCreate hook — creates jj workspace pinned to @- |
| `plugins/project-setup-jj/scripts/jj-workspace-remove.sh` | Create (copy) | WorktreeRemove hook — forgets workspace and removes directory |
| `plugins/project-setup-jj/templates/CLAUDE.md.template` | Modify | Add fan-flames override row, update hash |
| `plugins/project-setup-jj/commands/project-setup.md` | Modify | Add workspace script copy step, add workspace hooks to settings merge, update confirmation |
| `plugins/workspace-jj/commands/workspace-setup.md` | Delete | No longer needed |

---

### Task 1: Copy workspace scripts into project-setup-jj

**Files:**
- Create: `plugins/project-setup-jj/scripts/jj-workspace-create.sh`
- Create: `plugins/project-setup-jj/scripts/jj-workspace-remove.sh`

- [ ] **Step 1: Copy jj-workspace-create.sh**

```bash
cp plugins/workspace-jj/scripts/jj-workspace-create.sh plugins/project-setup-jj/scripts/jj-workspace-create.sh
```

- [ ] **Step 2: Copy jj-workspace-remove.sh**

```bash
cp plugins/workspace-jj/scripts/jj-workspace-remove.sh plugins/project-setup-jj/scripts/jj-workspace-remove.sh
```

- [ ] **Step 3: Verify both files are executable**

```bash
chmod +x plugins/project-setup-jj/scripts/jj-workspace-create.sh
chmod +x plugins/project-setup-jj/scripts/jj-workspace-remove.sh
ls -la plugins/project-setup-jj/scripts/jj-workspace-*.sh
```

Expected: Both files present with execute permission.

- [ ] **Step 4: Verify contents match source**

```bash
diff plugins/workspace-jj/scripts/jj-workspace-create.sh plugins/project-setup-jj/scripts/jj-workspace-create.sh
diff plugins/workspace-jj/scripts/jj-workspace-remove.sh plugins/project-setup-jj/scripts/jj-workspace-remove.sh
```

Expected: No differences.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(project-setup): copy workspace scripts from workspace-jj"
```

---

### Task 2: Update CLAUDE.md template

**Files:**
- Modify: `plugins/project-setup-jj/templates/CLAUDE.md.template`

- [ ] **Step 1: Read current template**

Read `plugins/project-setup-jj/templates/CLAUDE.md.template` to see current content.

- [ ] **Step 2: Add fan-flames override row**

Add the following row to the superpowers overrides table, before the `<!-- jj-project-setup:end -->` marker:

```markdown
| `subagent-driven-development` | `workspace-jj:fan-flames` | jj-native: wave-based parallel execution with spec review gates |
```

The table should now have two rows:

```markdown
| Superpowers skill | Use instead | Why |
|---|---|---|
| `finishing-a-development-branch` | `/finish` | jj-native: bookmarks, `jj git push`, workspace cleanup |
| `subagent-driven-development` | `workspace-jj:fan-flames` | jj-native: wave-based parallel execution with spec review gates |
```

- [ ] **Step 3: Recalculate content hash**

Generate a new hash from the content between (and including) the start/end markers. Use the same hashing approach as the existing template:

```bash
# Extract content between markers (inclusive) and hash it
sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' plugins/project-setup-jj/templates/CLAUDE.md.template | sed 's/hash:[a-f0-9]*/hash:PLACEHOLDER/' | md5 | cut -c1-8
```

Update the `hash:` value in the `<!-- jj-project-setup:start hash:XXXXXXXX -->` marker with the new hash.

- [ ] **Step 4: Verify template is well-formed**

Read the file and confirm:
- Start marker has updated hash
- Table has two override rows
- End marker is present

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(project-setup): add fan-flames override to CLAUDE.md template"
```

---

### Task 3: Update /project-setup command

**Files:**
- Modify: `plugins/project-setup-jj/commands/project-setup.md`

This task has three sub-changes: add workspace script copy step, add workspace hooks to settings merge, update confirmation.

- [ ] **Step 1: Read current project-setup command**

Read `plugins/project-setup-jj/commands/project-setup.md` to see current steps.

- [ ] **Step 2: Add Step 5 — copy workspace hook scripts**

After the current Step 4 (copy require-jj-new hook script + merge PreToolUse hook), insert a new step:

```markdown
### Step 5: Copy workspace hook scripts

Copy workspace scripts from the plugin's `scripts/` directory to the project's `.claude/scripts/`:

\`\`\`bash
cp <plugin-scripts-dir>/jj-workspace-create.sh "$(jj root)/.claude/scripts/"
cp <plugin-scripts-dir>/jj-workspace-remove.sh "$(jj root)/.claude/scripts/"
chmod +x "$(jj root)/.claude/scripts/jj-workspace-create.sh"
chmod +x "$(jj root)/.claude/scripts/jj-workspace-remove.sh"
\`\`\`

Then merge WorktreeCreate and WorktreeRemove hook entries into `.claude/settings.local.json` (using the same deep-merge strategy as Steps 3 and 4):

\`\`\`json
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
\`\`\`

Replace `<project-root>` with the actual absolute path from `jj root`.
```

- [ ] **Step 3: Renumber subsequent steps**

Renumber the existing Step 5 (Create or update CLAUDE.md) to Step 6, and Step 6 (Confirm to user) to Step 7.

- [ ] **Step 4: Update confirmation step (now Step 7)**

In the confirmation step, add workspace hooks to the summary list:

```markdown
- WorktreeCreate hook script copied to `.claude/scripts/jj-workspace-create.sh`
- WorktreeRemove hook script copied to `.claude/scripts/jj-workspace-remove.sh`
- Settings updated with WorktreeCreate and WorktreeRemove hooks
```

Remove the line:
```
- Optionally run `/workspace-setup` if they want worktree isolation via jj workspaces
```

- [ ] **Step 5: Verify the command file is coherent**

Read the full file and confirm:
- Steps are numbered 1-7 sequentially
- No references to `/workspace-setup`
- WorktreeCreate/WorktreeRemove hooks included in Step 5
- Confirmation lists all hooks (SessionStart, PreToolUse, WorktreeCreate, WorktreeRemove)

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(project-setup): add workspace hooks to /project-setup command"
```

---

### Task 4: Delete /workspace-setup command

**Files:**
- Delete: `plugins/workspace-jj/commands/workspace-setup.md`

- [ ] **Step 1: Verify the file exists**

```bash
ls plugins/workspace-jj/commands/workspace-setup.md
```

- [ ] **Step 2: Delete the file**

```bash
rm plugins/workspace-jj/commands/workspace-setup.md
```

- [ ] **Step 3: Verify workspace-jj still has its other commands and skills**

```bash
ls plugins/workspace-jj/commands/
ls plugins/workspace-jj/skills/
```

Expected:
- `commands/`: `workspace-list.md` (only)
- `skills/`: `fan-flames.md`, `fan-flames-spec-reviewer.md`

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(workspace-jj): remove /workspace-setup (consolidated into /project-setup)"
```

---

### Task 5: Validation

**Files:**
- Read: all modified files

- [ ] **Step 1: Verify project-setup-jj has all scripts**

```bash
ls plugins/project-setup-jj/scripts/
```

Expected: `block-raw-git.sh`, `jj-session-start.sh`, `jj-workspace-create.sh`, `jj-workspace-remove.sh`, `require-jj-new.sh`, `statusline-jj.sh`

- [ ] **Step 2: Verify workspace-jj no longer has workspace-setup**

```bash
ls plugins/workspace-jj/commands/
```

Expected: `workspace-list.md` only.

- [ ] **Step 3: Verify CLAUDE.md template has fan-flames row**

```bash
grep "fan-flames" plugins/project-setup-jj/templates/CLAUDE.md.template
```

Expected: line with `subagent-driven-development` → `workspace-jj:fan-flames`

- [ ] **Step 4: Verify project-setup command references workspace scripts**

```bash
grep "workspace-create" plugins/project-setup-jj/commands/project-setup.md
grep "workspace-remove" plugins/project-setup-jj/commands/project-setup.md
grep "WorktreeCreate" plugins/project-setup-jj/commands/project-setup.md
grep "WorktreeRemove" plugins/project-setup-jj/commands/project-setup.md
```

Expected: all four patterns found.

- [ ] **Step 5: Verify no references to /workspace-setup remain**

```bash
grep -r "workspace-setup" plugins/project-setup-jj/ || echo "clean"
grep -r "/workspace-setup" plugins/workspace-jj/ || echo "clean"
```

Expected: "clean" for both.

- [ ] **Step 6: Final commit**

```bash
jj describe -m "feat(project-setup): consolidate workspace-setup into project-setup

- Copy jj-workspace-create.sh and jj-workspace-remove.sh into project-setup-jj
- Add WorktreeCreate/WorktreeRemove hooks to /project-setup command
- Add fan-flames override row to CLAUDE.md template
- Delete /workspace-setup command from workspace-jj
- One command now installs all jj hooks including workspace isolation"
```
