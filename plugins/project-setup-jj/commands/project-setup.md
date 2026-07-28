---
description: Bootstrap jj (Jujutsu) workflow enforcement for this project
allowed-tools: Bash(jj:*), Bash(bash:*)
---

## Your Task

Bootstrap jj (Jujutsu) workflow enforcement for the current project: install the SessionStart / PreCompact / PreToolUse / Worktree hooks, jj permissions, and the CLAUDE.md VCS section.

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Steps

### Step 1: Gate on a jj repo

Run `jj root`. If it fails, tell the user `/project-setup` requires a jj repository and stop. Otherwise capture the project root.

### Step 2: Run the installer

All install work is done by a deterministic script — do not hand-merge settings or edit CLAUDE.md yourself. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-setup-install.sh" "${CLAUDE_PLUGIN_ROOT}" "$(jj root)"
```

The script copies the four hook handlers into `.claude/hooks/`, deep-merges the hooks and permissions into `.claude/settings.local.json` (idempotently — re-running never duplicates entries and never touches unrelated config), and creates/updates the CLAUDE.md `## VCS` section. It prints a `key=value` summary and exits non-zero without writing if an existing `.claude/settings.local.json` is not valid JSON (in which case, report the error and stop — do not attempt to repair it automatically).

Earlier versions installed these handlers into `.claude/scripts/`. The script migrates such a project in one run: it re-points the registrations (replacing the old ones rather than adding a second copy beside them) and deletes the four files it owns from `.claude/scripts/`, removing that directory only if nothing else is left in it. Files it does not own — notably `statusline-jj.sh` from `/statusline-jj-setup` — are left alone.

### Step 3: Report

Read the script's `key=value` summary and confirm to the user what was set up:

- Hook handlers installed in `.claude/hooks/` (SessionStart, require-jj-new, workspace create/remove)
- `.claude/settings.local.json` updated (SessionStart + PreCompact + PreToolUse + WorktreeCreate + WorktreeRemove hooks + jj permissions) — value from `settings=`
- Legacy `.claude/scripts/` — per the `legacy_scripts=` value: `removed` (migrated and the empty directory cleaned up), `kept_not_empty` (our files removed, directory kept because other files such as `statusline-jj.sh` remain), or `absent` (nothing to migrate)
- CLAUDE.md — `created`, `updated`, or `already up to date` per the `claude_md=` value

Then remind the user to:
- **Restart Claude Code** for the hooks to take effect
- Optionally add `.claude/hooks/` to their ignore patterns if they don't want these tracked
