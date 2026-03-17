# Claude Code Plugins for jj (Jujutsu)

Claude Code plugins for **jj (Jujutsu)** workflows — project setup, worktree isolation via jj workspaces, commit management, and peer review.

All plugins include a `PreToolUse` hook (`block-raw-git.sh`) that intercepts Bash tool calls and blocks raw `git` commands, keeping your workflow pure jj. When Claude reaches for `git add` or `git commit`, the hook catches it and suggests the jj equivalent.

All jj output commands (`jj log`, `jj diff`, `jj bookmark list`, `jj op log`, `jj workspace list`, `jj show`, `jj evolog`, `jj op show`, `jj config list`, `jj tag list`) use JSON templates (`-T 'json(self)'`) by default, giving Claude Code structured, machine-parseable output instead of human-readable text. Requires jj >= 0.31.0.

## Plugins

| Plugin | Description | Commands | Agents |
|--------|-------------|:--------:|:------:|
| **project-setup-jj** | Bootstrap jj workflow enforcement with `/project-setup` | 1 | — |
| **workspace-jj** | Worktree isolation for jj repos via `jj workspace` hooks | 2 | — |
| **commit-commands-jj** | jj commit workflows — commit, push, PR creation, and more | 14 | — |
| **peer-review-jj** | Unified change review — generalist-first with emergent specialists | 1 | 1 |

## project-setup-jj

Bootstrap jj workflow enforcement for any project with a single command. Sets up a SessionStart hook (shows jj context each session), a PreToolUse guard hook (prompts `jj new` before editing non-empty changes), permissions (allow jj/gh, deny git), and a CLAUDE.md policy directive.

**Setup:**

```bash
# 1. Install from plugin manager
/plugin install project-setup-jj@muloka-claude-plugins

# 2. Run setup in your jj project
/project-setup

# 3. Restart Claude Code for SessionStart hook
```

**Requires:** [jj](https://martinvonz.github.io/jj/) and [jq](https://jqlang.github.io/jq/)

## workspace-jj

Enables Claude Code's `--worktree` flag and subagent `isolation: "worktree"` in jj repositories. Claude Code uses git worktrees by default for isolated parallel sessions — this plugin replaces that with jj workspaces via `WorktreeCreate` and `WorktreeRemove` hooks, so `--worktree` works natively in jj repos.

**Setup:**

```bash
# 1. Install from plugin manager
/plugin install workspace-jj@muloka-claude-plugins

# 2. Run setup in your jj project (copies hook scripts, configures settings)
/workspace-setup

# 3. Restart Claude Code, then use worktrees
claude --worktree feature-auth
```

Claude Code doesn't pick up `WorktreeCreate`/`WorktreeRemove` hooks from plugins — they must be in project settings. The `/workspace-setup` command handles this by copying scripts to `.claude/scripts/` and configuring `.claude/settings.local.json`.

**Requires:** [jj](https://martinvonz.github.io/jj/) and [jq](https://jqlang.github.io/jq/)

## commit-commands-jj

Streamline your jj commit workflow with simple slash commands.

**Commands:** `/commit`, `/commit-push-pr`, `/new`, `/edit`, `/describe`, `/squash`, `/abandon`, `/sync`, `/undo`, `/finish`, `/clean_stale`, `/show`, `/evolog`, `/op-show`, `/tag-list`

## peer-review-jj

Unified change review for jj repos. Two-phase pipeline (requesting → receiving) with generalist-first architecture and emergent specialists.

**Command:** `/peer-review`

```
/peer-review                          # review current change (@)
/peer-review <revision>               # review specific change
/peer-review --deep errors types      # generalist + specialist dispatch
/peer-review --track                  # enable progress tracking (duplicate+squash)
/peer-review --post                   # post findings to GitHub PR
/peer-review --json                   # raw structured output
```

**Agent:** `change-reviewer` — generalist reviewer that scales with change size (1 per ~300 lines). Returns structured JSON findings with severity tiers and confidence scoring (>= 80 threshold). Recommends specialists for deeper analysis when needed.

**Specialist emergence:** After 3+ reviews flag distinct patterns for a concern type, the plugin prompts to create a project-specific specialist at `.claude/peer-review/specialists/`.

Replaces the deprecated `code-review-jj`, `pr-review-toolkit-jj`, and `feature-dev-jj` plugins. See [design doc](docs/peer-review-jj/2026-03-16-peer-review-jj-design.md) for full details.

## Installation

Add the marketplace and install plugins via the plugin manager:

```
/plugin marketplace add muloka/claude-plugins
/plugin install peer-review-jj@muloka-claude-plugins
```

Or browse available plugins:

```
/plugin
```

**Note:** After installing workspace-jj, run `/workspace-setup` in your jj project and restart Claude Code.

## Acknowledgments

Originally modelled off of Anthropic's [claude-plugins-official](https://github.com/anthropics/claude-plugins-official).

## License

See each plugin directory for the relevant LICENSE file.
