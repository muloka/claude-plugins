# Plan: `project-setup-jj` Plugin

## Context

When starting a new Claude Code project that uses jj (Jujutsu), there's no automated way to bootstrap jj workflow enforcement. The existing plugins (commit-commands-jj, workspace-jj, etc.) provide commands and git-blocking hooks, but nothing that:
- Shows jj context when a session starts
- Configures hookify rules for workflow reminders
- Sets up CLAUDE.md with jj instructions
- Pre-configures permissions for jj commands

This plugin adds a `/project-setup` command that does all of the above in one step, following the established pattern of `/workspace-setup`.

## Implementation Workflow (jj)

Before writing any code, follow the jj workflow:

```bash
jj new                                        # start a fresh change
jj describe -m "Add project-setup-jj plugin"  # set intent upfront
# ... do all the implementation work ...
jj diff                                       # review before finalizing
# then use /commit-push-pr to finalize + open PR
```

This plan itself should be implemented following this pattern.

---

## New Plugin: `project-setup-jj`

### File Structure

```
plugins/project-setup-jj/
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   └── project-setup.md
├── scripts/
│   ├── block-raw-git.sh          # copied from commit-commands-jj
│   └── jj-session-start.sh       # NEW: SessionStart hook
├── templates/
│   ├── CLAUDE.md.template         # jj workflow instructions
│   ├── hookify.warn-raw-git.local.md
│   ├── hookify.require-jj-workflow.local.md
│   └── hookify.warn-git-internals.local.md
├── README.md
└── LICENSE
```

### What `/project-setup` Does (6 Steps)

**Step 1: Detect context**
- Verify jj repo (`jj root`)
- Locate plugin's scripts/templates directory (relative to command file)
- Ensure `.claude/` and `.claude/scripts/` exist in project root

**Step 2: Copy SessionStart hook script**
- Copy `jj-session-start.sh` → project's `.claude/scripts/`
- `chmod +x`

**Step 3: Update `.claude/settings.local.json`**
- Deep-merge using `jq` (same approach as workspace-setup)
- Add SessionStart hook pointing to `.claude/scripts/jj-session-start.sh`
- Add permissions: allow jj commands + gh CLI, deny raw git
- Deduplicate entries, preserve existing config

**Step 4: Create hookify rules**
- Copy 3 template `.local.md` files → project's `.claude/`
- Skip if identical file already exists

**Step 5: Create/update CLAUDE.md**
- If no CLAUDE.md exists: create from template
- If CLAUDE.md exists with `<!-- jj-project-setup:start -->` marker: replace that section
- If CLAUDE.md exists without marker: prepend jj section with markers, preserve existing content

**Step 6: Confirm to user**
- Show what was created/updated
- Remind to restart Claude Code for SessionStart hook
- Mention `/workspace-setup` as optional next step for worktree isolation

---

## Key Files to Create

### 1. `plugin.json`

Standard manifest with PreToolUse hook for block-raw-git (matching all other jj plugins).

### 2. `jj-session-start.sh` (SessionStart hook)

**Informational only** — does NOT auto-run `jj new`. Outputs:

```
== jj Session Context ==

Current change:
<output of jj log -r @ --no-graph>

Working copy status:
<output of jj status>

== jj Workflow Reminder ==
- Use `jj new` to start a fresh change before making edits
- Use `jj describe -m "..."` to set intent on the current change
- Use `jj diff` to review working copy changes
- Never use raw git commands — use jj equivalents
```

Output format: JSON with `additionalContext` field, following the superpowers SessionStart hook pattern (`escape_for_json()` for proper escaping).

If not in a jj repo (`jj root` fails), exits silently.

### 3. Hookify Rules (3 templates)

| Rule | Event | Action | Purpose |
|------|-------|--------|---------|
| `warn-raw-git` | bash | warn | Nudge message when git detected (actual blocking done by plugin hook) |
| `require-jj-workflow` | stop | warn | Remind if `jj new` was never run during the session |
| `warn-git-internals` | bash | warn | Catch `.git/` access, `git config`, `git rev-parse` |

All rules use `action: warn` (not block) — the plugin-level `block-raw-git.sh` handles hard blocking. Hookify provides supplementary reminders.

### 4. CLAUDE.md Template

Contains:
- jj-only VCS policy
- 7-step workflow guide (status → new → describe → work → diff → commit → push)
- Full Git→jj translation table (18 commands)
- Key jj concepts (no staging, changes vs commits, bookmarks, undo)

Wrapped in `<!-- jj-project-setup:start/end -->` markers for idempotent updates.

### 5. Permissions Config

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

---

## Reference Files

- **Pattern to follow:** `plugins/workspace-jj/commands/workspace-setup.md` — command structure, frontmatter, step-by-step format
- **SessionStart hook format:** Anthropic's superpowers plugin SessionStart hook — JSON output with `additionalContext`, `escape_for_json()`
- **Block script:** `plugins/commit-commands-jj/scripts/block-raw-git.sh` — copy directly
- **Hookify rules engine:** `hookify/core/rule_engine.py` — confirms `transcript` field only works in Stop events
- **Real-world settings example:** `tokotoko/.claude/settings.local.json` — shows configured hook JSON structure

## Verification

1. Install the plugin, run `/project-setup` in a jj repo
2. Verify `.claude/scripts/jj-session-start.sh` exists and is executable
3. Verify `.claude/settings.local.json` has SessionStart hook + permissions
4. Verify `.claude/hookify.*.local.md` files exist (3 rules)
5. Verify CLAUDE.md has jj workflow section
6. Restart Claude Code — confirm SessionStart shows jj context
7. Try a raw `git status` — confirm it's blocked
8. Run a session without `jj new`, then stop — confirm workflow reminder appears
9. Re-run `/project-setup` — confirm idempotent (no duplicates)
