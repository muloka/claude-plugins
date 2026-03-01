# Claude Code Plugins for jj (Jujutsu)

Claude Code plugins for **jj (Jujutsu)** workflows — commit management, code review, PR review, and feature development.

All plugins include a `PreToolUse` hook (`block-raw-git.sh`) that intercepts Bash tool calls and blocks raw `git` commands, keeping your workflow pure jj.

## Plugins

| Plugin | Description | Commands | Agents |
|--------|-------------|:--------:|:------:|
| **commit-commands-jj** | jj commit workflows — commit, push, PR creation, and more | 10 | — |
| **code-review-jj** | Automated code review with confidence-based scoring | 1 | — |
| **pr-review-toolkit-jj** | Specialized PR review agents | 1 | 6 |
| **feature-dev-jj** | Feature development with exploration, architecture, and review | 1 | 3 |

## commit-commands-jj

Streamline your jj commit workflow with simple slash commands.

**Commands:** `/commit`, `/commit-push-pr`, `/new`, `/edit`, `/describe`, `/squash`, `/abandon`, `/sync`, `/undo`, `/clean_stale`

## code-review-jj

Automated code review for pull requests using confidence-based scoring.

**Command:** `/code-review`

## pr-review-toolkit-jj

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

## feature-dev-jj

Guided feature development workflow with three specialized agents:

| Agent | Purpose |
|-------|---------|
| **code-explorer** | Deep codebase analysis — traces execution paths, maps architecture |
| **code-architect** | Designs feature architectures following existing patterns and conventions |
| **code-reviewer** | Reviews code for bugs, logic errors, security vulnerabilities, and quality |

**Command:** `/feature-dev`

## Installation

Install any plugin directly from GitHub using Claude Code:

```
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/commit-commands-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/code-review-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/pr-review-toolkit-jj
/install-plugin https://github.com/muloka/claude-plugins/tree/main/plugins/feature-dev-jj
```

## License

See each plugin directory for the relevant LICENSE file.
