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

If the user passed `--local` to `/project-setup`, forward it as the first argument:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-setup-install.sh" --local "${CLAUDE_PLUGIN_ROOT}" "$(jj root)"
```

The script copies the four hook handlers into `.claude/hooks/` and creates/updates the CLAUDE.md `## VCS` section. Settings are split (#97):

- **`.claude/settings.json`** — hooks and `permissions.deny`. Meant to be committed, so a fresh clone or `jj workspace add` checkout enforces the same rules. This is the default.
- **`.claude/settings.local.json`** — `permissions.allow`, plus `statusLine` if `/statusline-jj-setup` is used. Personal, stays untracked.

Both merges are idempotent — re-running never duplicates entries and never touches unrelated config. A tracked install also **removes** the managed hooks from `settings.local.json`: hooks merge additively across scopes, so a registration present in both files fires twice.

`--local` writes everything to `settings.local.json` and touches no tracked path, which is the pre-#97 behaviour.

It prints a `key=value` summary and exits non-zero without writing if an existing settings file is not valid JSON (report the error and stop — do not attempt to repair it automatically).

**Exit 3 — `.gitignore` excludes `.claude/`.** Tracked mode aborts, having written nothing, because neither git nor jj can re-include a file under an excluded directory: a tracked `settings.json` there could never be committed, and adding `!.claude/settings.json` below the blanket rule has no effect. The script prints the replacement rules. Relay them, and offer the two options — narrow the ignore rule and re-run, or re-run with `--local`. Do not edit the user's `.gitignore` yourself.

Earlier versions installed these handlers into `.claude/scripts/`. The script migrates such a project in one run: it re-points the registrations (replacing the old ones rather than adding a second copy beside them) and deletes the four files it owns from `.claude/scripts/`, removing that directory only if nothing else is left in it. Files it does not own — notably `statusline-jj.sh` from `/statusline-jj-setup` — are left alone.

### Step 3: Report

Read the script's `key=value` summary and confirm to the user what was set up:

- Hook handlers installed in `.claude/hooks/` (SessionStart, require-jj-new, workspace create/remove)
- Which layout was used — value from `mode=` (`tracked` or `local`)
- `.claude/settings.json` — hooks (SessionStart, PreCompact, PreToolUse, WorktreeCreate, WorktreeRemove) + the `Bash(git *)` deny floor — value from `settings_tracked=` (`created`, `merged`, or `skipped` in `--local` mode). **Tell the user to commit this file** — that is what makes fresh clones and jj workspaces enforce the rules.
- `.claude/settings.local.json` — jj/gh allow-list, and in `--local` mode the hooks too — value from `settings=`
- Legacy `.claude/scripts/` — per the `legacy_scripts=` value: `removed` (migrated and the empty directory cleaned up), `kept_not_empty` (our files removed, directory kept because other files such as `statusline-jj.sh` remain), or `absent` (nothing to migrate)
- CLAUDE.md — `created`, `updated`, or `already up to date` per the `claude_md=` value
- Smoke test — value from `smoke=`. `pass` means the copied handlers parse, are
  executable, and `jj-session-start.sh` actually ran and emitted valid JSON.
  `fail:<reason>` means the install is written and registered but a handler does
  not work — report the reason verbatim rather than the summary word, and do not
  present the setup as ready. This key exists because #88 shipped a handler that
  was copied, registered, announced, and dead, with every suite green: they
  covered the installer, not the installed result.

Then remind the user to:
- **Restart Claude Code** for the hooks to take effect
- Optionally add `.claude/hooks/` to their ignore patterns if they don't want these tracked
