# Claude Code Plugins for jj (Jujutsu)

Claude Code plugins for **jj (Jujutsu)** workflows — project setup, worktree isolation via jj workspaces, commit management, code review, PR review, and feature development.

All plugins include a `PreToolUse` hook (`block-raw-git.sh`) that intercepts Bash tool calls and blocks raw `git` commands, keeping your workflow pure jj. When Claude reaches for `git add` or `git commit`, the hook catches it and suggests the jj equivalent.

## Plugins

| Plugin | Description | Commands | Agents |
|--------|-------------|:--------:|:------:|
| **project-setup-jj** | Bootstrap jj workflow enforcement with `/project-setup` | 1 | — |
| **workspace-jj** | Worktree isolation for jj repos via `jj workspace` hooks | 1 | — |
| **commit-commands-jj** | jj commit workflows — commit, push, PR creation, and more | 10 | — |
| **code-review-jj** | Automated code review with confidence-based scoring | 1 | — |
| **pr-review-toolkit-jj** | Specialized PR review agents | 1 | 6 |
| **feature-dev-jj** | Feature development with exploration, architecture, and review | 1 | 3 |
| **hookify** | Patched fork — prevent unwanted behaviors via conversation analysis | 4 | 1 |

## project-setup-jj

Bootstrap jj workflow enforcement for any project with a single command. Sets up a SessionStart hook (shows jj context each session), hookify rules (warn on raw git usage), permissions (allow jj/gh, deny git), and a CLAUDE.md policy directive.

**Setup:**

```bash
# 1. Install
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/project-setup-jj

# 2. Run setup in your jj project
/project-setup

# 3. Restart Claude Code for SessionStart hook
```

**Requires:** [jj](https://martinvonz.github.io/jj/) and [jq](https://jqlang.github.io/jq/)

## workspace-jj

Enables Claude Code's `--worktree` flag and subagent `isolation: "worktree"` in jj repositories. Claude Code uses git worktrees by default for isolated parallel sessions — this plugin replaces that with jj workspaces via `WorktreeCreate` and `WorktreeRemove` hooks, so `--worktree` works natively in jj repos.

**Setup:**

```bash
# 1. Install
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/workspace-jj

# 2. Run setup in your jj project (copies hook scripts, configures settings)
/workspace-setup

# 3. Restart Claude Code, then use worktrees
claude --worktree feature-auth
```

Claude Code doesn't pick up `WorktreeCreate`/`WorktreeRemove` hooks from plugins — they must be in project settings. The `/workspace-setup` command handles this by copying scripts to `.claude/scripts/` and configuring `.claude/settings.local.json`.

**Requires:** [jj](https://martinvonz.github.io/jj/) and [jq](https://jqlang.github.io/jq/)

## commit-commands-jj

Streamline your jj commit workflow with simple slash commands.

**Commands:** `/commit`, `/commit-push-pr`, `/new`, `/edit`, `/describe`, `/squash`, `/abandon`, `/sync`, `/undo`, `/clean_stale`

## code-review-jj

Automated code review for pull requests using confidence-based scoring.

**Command:** `/code-review`

## pr-review-toolkit-jj

Comprehensive PR review using six specialized agents, each running a focused pass:

| Agent | Purpose |
|-------|---------|
| **code-reviewer** | Style guide adherence, best practices, project conventions |
| **silent-failure-hunter** | Silent failures, inadequate error handling, swallowed exceptions |
| **code-simplifier** | Code clarity, consistency, and maintainability |
| **comment-analyzer** | Comment accuracy, completeness, and long-term maintainability |
| **pr-test-analyzer** | Test coverage quality and completeness |
| **type-design-analyzer** | Type encapsulation, invariant expression, and design quality |

**Command:** `/review-pr`

## feature-dev-jj

Guided feature development pipeline — explore, then architect, then review:

| Agent | Phase |
|-------|-------|
| **code-explorer** | Deep codebase analysis — traces execution paths, maps architecture |
| **code-architect** | Designs feature architectures following existing patterns and conventions |
| **code-reviewer** | Reviews code for bugs, logic errors, security vulnerabilities, and quality |

**Command:** `/feature-dev`

## hookify (patched fork)

Temporary fork of [hookify](https://github.com/anthropics/claude-code/tree/main/plugins/hookify) from `anthropics/claude-code` with a bug fix for `stop` event rules leaking into `PostToolUse` context for unrecognized tools (e.g., Agent). This caused `require-jj-workflow` warnings to fire spuriously in plan mode after subagent completion.

**Fix:** `config_loader.py` — changed `if event:` to `if event is not None:` so `None` (unrecognized tool) still filters out `stop`/`bash`/`file` rules instead of bypassing the filter entirely.

**Dependency:** The `project-setup-jj` plugin installs hookify rules (e.g., `require-jj-workflow`). If you use `project-setup-jj`, install this patched hookify instead of the upstream version.

This fork will be removed once the fix is merged upstream.

## Installation

Install any plugin directly from GitHub using Claude Code:

```
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/project-setup-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/workspace-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/commit-commands-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/code-review-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/pr-review-toolkit-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/feature-dev-jj
```

**Note:** After installing workspace-jj, run `/workspace-setup` in your jj project and restart Claude Code.

## Acknowledgments

Originally modelled off of Anthropic's [claude-plugins-official](https://github.com/anthropics/claude-plugins-official).

## License

See each plugin directory for the relevant LICENSE file.
