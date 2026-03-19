# Claude Code Plugins for jj (Jujutsu)

Claude Code plugins for **jj (Jujutsu)** workflows — project setup, workspace isolation, commit management, peer review, and autonomous permission gating.

The jj plugins (project-setup, workspace, commit-commands, peer-review) include a `PreToolUse` hook (`block-raw-git.sh`) that intercepts Bash tool calls and blocks raw `git` commands, keeping your workflow pure jj. When Claude reaches for `git add` or `git commit`, the hook catches it and suggests the jj equivalent. Permission-gateway is a standalone plugin that works in any repo (jj or git).

All jj output commands (`jj log`, `jj diff`, `jj bookmark list`, `jj op log`, `jj workspace list`, `jj show`, `jj evolog`, `jj op show`, `jj config list`, `jj tag list`) use JSON templates (`-T 'json(self)'`) by default, giving Claude Code structured, machine-parseable output instead of human-readable text. Requires jj >= 0.31.0.

## Plugins

| Plugin | Description | Commands | Agents |
|--------|-------------|:--------:|:------:|
| **project-setup-jj** | Bootstrap jj workflow enforcement with `/project-setup` | 1 | — |
| **workspace-jj** | Worktree isolation for jj repos via `jj workspace` hooks | 2 | — |
| **commit-commands-jj** | jj commit workflows — commit, push, PR creation, and more | 14 | — |
| **peer-review-jj** | Unified change review — generalist-first with emergent specialists | 1 | 1 |
| **permission-gateway** | Tiered permission gating — zero-config, self-tuning | 1 | — |

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

## permission-gateway

Tiered permission gateway for autonomous subagent workflows. When running multiple subagents in parallel, each making dozens of tool calls, you either pre-approve everything (dangerous) or get 60+ confirmation prompts (kills parallelism). Permission gateway is the middle ground.

**Evaluation order:** Gate-the-Gate → Deny (immutable floor) → `.local.md` rules → Confirm → Approve → Tier 2 (LLM eval)

```
Tool call fires
     │
     ▼
 Gate → Deny → .local.md → Confirm → Approve → Tier 2 LLM
  │      │         │          │          │          │
  ▼      ▼         ▼          ▼          ▼          ▼
PROMPT BLOCK    per rule    PROMPT    SILENT     LLM+PROMPT
```

**Security:** One-way ratchet — hardcoded deny is an immutable floor that `.local.md` cannot override. Writes to permission-gateway config files require human confirmation (gate-the-gate). Dangerous patterns are scanned in the full command string to prevent bypass via `find -exec`, `xargs`, or redirect clobbers.

**Self-tuning:** All decisions logged to `.claude/permission-gateway.log`. Review the log to promote frequently-confirmed commands to `.local.md` approve rules.

**Commands:** `/tune` — scan decision log and propose `.local.md` rule promotions

**Requires:** [jq](https://jqlang.github.io/jq/). Tier 2 uses Claude Code's built-in prompt hook evaluation — no separate API key or CLI needed.

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

## Relationship to claude-plugins-official

This repo started as a fork of Anthropic's [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) and has evolved through two phases:

**Phase 1: jj translations** — Replaced Anthropic's git-based plugins (`commit-commands`, `code-review`, `feature-dev`, `pr-review-toolkit`) with jj-native equivalents. Same capabilities, different VCS.

**Phase 2: jj-native capabilities** — Built features that leverage jj's model in ways git can't easily support. Lightweight workspaces for parallel subagent isolation (fan-flames), first-class conflicts for multi-workspace merging, automatic working-copy snapshots eliminating the commit/stage ceremony, and operation-log-based undo for safe experimentation. These aren't ports of git workflows — they're new patterns that emerge from jj's architecture.

| Category | This repo | Anthropic original |
|----------|-----------|-------------------|
| **VCS** | jj (Jujutsu) — all plugins enforce jj-only | git |
| **Commits** | `commit-commands-jj` — jj-native with revsets, bookmarks, operation log | `commit-commands` — git add/commit/push |
| **Code review** | `peer-review-jj` — generalist-first, emergent specialists, structured findings | `code-review` — single-pass review |
| **Workspace isolation** | `workspace-jj` — jj workspaces via WorktreeCreate/Remove hooks | Not provided (git worktrees are built-in) |
| **Permission gating** | `permission-gateway` — tiered evaluation, one-way ratchet, self-tuning | Not provided |
| **Project setup** | `project-setup-jj` — jj workflow enforcement, statusline, SessionStart hooks | Not provided |

**Removed from original:** `code-review`, `commit-commands`, `feature-dev`, `pr-review-toolkit` — replaced by jj-native equivalents above.

**Net new (no upstream equivalent):** `permission-gateway`, `workspace-jj`, `project-setup-jj`, fan-flames skill.

## License

See each plugin directory for the relevant LICENSE file.
