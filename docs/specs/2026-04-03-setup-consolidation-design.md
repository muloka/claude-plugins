# Setup Consolidation: Fold workspace-setup into project-setup

**Date:** 2026-04-03
**Status:** Draft
**Plugins affected:** `project-setup-jj`, `workspace-jj`

---

## Problem

`/project-setup` writes a CLAUDE.md override table referencing fan-flames, but fan-flames won't work without WorktreeCreate/WorktreeRemove hooks that only `/workspace-setup` installs. This creates a broken reference — the user runs one setup command and gets a half-configured system.

## Solution

Fold `/workspace-setup` into `/project-setup`. One command installs everything. `/workspace-setup` is removed from workspace-jj.

## Changes

### 1. project-setup-jj: Copy workspace scripts

`/project-setup` already copies `jj-session-start.sh` and `require-jj-new.sh` to `.claude/scripts/`. Add two more:

- `jj-workspace-create.sh` (from workspace-jj's `scripts/`)
- `jj-workspace-remove.sh` (from workspace-jj's `scripts/`)

These scripts are manually copied from workspace-jj's `scripts/` into project-setup-jj's `scripts/` directory and committed to the repo. This is a one-time development step, not a runtime operation. The plugin is then self-contained — no cross-plugin dependency at runtime.

### 2. project-setup-jj: Add WorktreeCreate/WorktreeRemove hooks

The `/project-setup` command's settings merge (Step 3) adds WorktreeCreate and WorktreeRemove hooks alongside the existing SessionStart and PreToolUse hooks:

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

Same deep-merge strategy as existing hooks — concatenate and deduplicate.

### 3. project-setup-jj: Update CLAUDE.md template

Add the fan-flames override row to `templates/CLAUDE.md.template`:

```markdown
| `subagent-driven-development` | `workspace-jj:fan-flames` | jj-native: wave-based parallel execution with spec review gates |
```

Update the content hash in the template's start marker to reflect the new content.

### 4. project-setup-jj: Update /project-setup command

Add a new Step 5 (after the existing require-jj-new step, renumbering current Step 5 → 6 and Step 6 → 7) to copy the workspace scripts:

```bash
cp <plugin-scripts-dir>/jj-workspace-create.sh "$(jj root)/.claude/scripts/"
cp <plugin-scripts-dir>/jj-workspace-remove.sh "$(jj root)/.claude/scripts/"
chmod +x "$(jj root)/.claude/scripts/jj-workspace-create.sh"
chmod +x "$(jj root)/.claude/scripts/jj-workspace-remove.sh"
```

Update Step 7 (confirmation, previously Step 6) to include workspace hooks in the summary:
- WorktreeCreate hook configured
- WorktreeRemove hook configured
- Remove the "optionally run `/workspace-setup`" suggestion

### 5. workspace-jj: Delete /workspace-setup command

Remove `plugins/workspace-jj/commands/workspace-setup.md`. workspace-jj keeps:
- `skills/fan-flames.md` (the skill)
- `skills/fan-flames-spec-reviewer.md` (the template)
- `commands/workspace-list.md` (still useful standalone)
- `scripts/jj-workspace-create.sh` (source of truth, copied by project-setup)
- `scripts/jj-workspace-remove.sh` (source of truth, copied by project-setup)

### 6. Idempotency

`/project-setup` is already idempotent:
- CLAUDE.md: hash-based detection skips if up-to-date
- settings.local.json: `jq` deep-merge deduplicates
- Scripts: `cp` overwrites safely

Adding workspace hooks follows the same patterns. Re-running `/project-setup` on a project that already has workspace hooks is a no-op.

**Migration:** Projects that previously ran `/workspace-setup` need no migration. Their hooks and scripts are already installed. When `/project-setup` is re-run post-consolidation, the deep-merge finds identical hooks and deduplicates. The CLAUDE.md hash will differ (new fan-flames row), triggering a template update.

---

## What This Spec Does NOT Cover

- **Removing workspace-jj scripts/** — the scripts remain in workspace-jj as the source of truth. project-setup-jj copies them into its own `scripts/` directory at plugin development time, not at runtime. This avoids a runtime cross-plugin dependency.
- **Changes to fan-flames skill** — already handled by the v2 spec.
- **Changes to /workspace-list** — stays in workspace-jj, unaffected.
