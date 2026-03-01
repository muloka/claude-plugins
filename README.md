# Claude Code Plugins for jj & Git

A collection of Claude Code plugins for **jj (Jujutsu)** and **git** workflows — commit management, code review, PR review, and feature development.

Each plugin family ships in two variants: a **jj** primary edition and a **git** edition. Install whichever matches your VCS.

## Plugins

| Plugin | Description | Commands | Agents |
|--------|-------------|:--------:|:------:|
| **commit-commands-jj** | jj commit workflows — commit, push, PR creation, and more | 10 | — |
| **commit-commands** | git commit workflows — commit, push, and PR creation | 3 | — |
| **code-review-jj** | Automated code review with confidence-based scoring (jj) | 1 | — |
| **code-review** | Automated code review with confidence-based scoring (git) | 1 | — |
| **pr-review-toolkit-jj** | Specialized PR review agents for jj repos | 1 | 6 |
| **pr-review-toolkit** | Specialized PR review agents for git repos | 1 | 6 |
| **feature-dev-jj** | Feature development workflow with exploration, architecture, and review (jj) | 1 | 3 |
| **feature-dev** | Feature development workflow with exploration, architecture, and review (git) | 1 | 3 |

## commit-commands

Streamline your commit workflow with simple slash commands.

**jj variant** — `/commit`, `/commit-push-pr`, `/new`, `/edit`, `/describe`, `/squash`, `/abandon`, `/sync`, `/undo`, `/clean_stale`

**git variant** — `/commit`, `/commit-push-pr`, `/clean_gone`

The jj variant includes a `block-raw-git.sh` hook that prevents accidental use of raw `git` commands in jj repositories.

## code-review

Automated code review for pull requests using confidence-based scoring.

**Command:** `/code-review`

Available in both jj and git variants. The jj variant includes the `block-raw-git.sh` enforcement hook.

## pr-review-toolkit

Comprehensive PR review using six specialized agents:

| Agent | Purpose |
|-------|---------|
| **code-reviewer** | Style guide adherence, best practices, project conventions |
| **silent-failure-hunter** | Silent failures, inadequate error handling, swallowed exceptions |
| **code-simplifier** | Code clarity, consistency, and maintainability |
| **comment-analyzer** | Comment accuracy, completeness, and long-term maintainability |
| **pr-test-analyzer** | Test coverage quality and completeness |
| **type-design-analyzer** | Type encapsulation, invariant expression, and design quality |

**Command:** `/review-pr`

Available in both jj and git variants. The jj variant includes the `block-raw-git.sh` enforcement hook.

## feature-dev

Guided feature development workflow with three specialized agents:

| Agent | Purpose |
|-------|---------|
| **code-explorer** | Deep codebase analysis — traces execution paths, maps architecture |
| **code-architect** | Designs feature architectures following existing patterns and conventions |
| **code-reviewer** | Reviews code for bugs, logic errors, security vulnerabilities, and quality |

**Command:** `/feature-dev`

Available in both jj and git variants. The jj variant includes the `block-raw-git.sh` enforcement hook.

## Installation

Install any plugin directly from GitHub using Claude Code:

```
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/commit-commands-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/code-review-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/pr-review-toolkit-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/feature-dev-jj
```

Replace `-jj` suffixes with the base name (e.g. `commit-commands`) for the git variants.

## jj vs Git Variants

Every plugin family has two editions:

- **`-jj` variants** — use `jj` commands, include a `PreToolUse` hook (`block-raw-git.sh`) that intercepts Bash tool calls and blocks raw `git` commands to keep your workflow pure jj.
- **base variants** — use standard `git` commands with no enforcement hooks.

Choose the variant that matches your VCS. Do not install both variants of the same plugin — they provide overlapping commands/agents.

## License

See each plugin directory for the relevant LICENSE file.
