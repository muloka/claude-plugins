# CONVENTIONS.md

Conventions for building Claude Code plugins in this repository.

## Plugin naming

- All plugin directories use a `-jj` suffix (e.g. `commit-commands-jj`, `workspace-jj`)
- Names are kebab-case, descriptive of function

## Plugin structure

Every plugin lives in `plugins/<name>/` and must include:

```
<name>/
  .claude-plugin/
    plugin.json          # manifest (required)
  commands/              # slash-command definitions
  scripts/               # shell scripts (hooks, helpers)
  README.md
  LICENSE                # Apache 2.0
```

Optional directories: `agents/`, `templates/`.

## jj enforcement

Three layers prevent raw git usage:

1. **PreToolUse hook** — Every plugin that exposes Bash registers `scripts/block-raw-git.sh` as a `PreToolUse` hook on `Bash` in its `plugin.json`. The script allows `jj git *`, `gh *`, and all non-git commands; blocks bare `git *`.

2. **CRITICAL warning block** — Every command and agent `.md` file begins (after YAML frontmatter) with a bold paragraph:

   > **CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands …**

   Commands that spawn sub-agents include a second paragraph instructing them to propagate the directive into every agent prompt.

3. **Project-level permissions** — The `project-setup` command writes `Bash(jj *)` to `allow` and `Bash(git *)` to `deny` in `.claude/settings.local.json`.

## Command conventions

Commands are Markdown files in `commands/` with YAML frontmatter:

```yaml
---
description: Short imperative description
allowed-tools: Bash(jj status:*), Bash(jj diff:*), Read, Write
argument-hint: "optional argument description"
---
```

Key patterns:

- **`allowed-tools`** — Tightly scoped per-subcommand: `Bash(jj diff:*)`, `Bash(gh pr create:*)`. Orchestrating commands that need broad access use the array form (`["Bash", "Glob", "Grep", "Read", "Task"]`) or omit the field entirely.
- **Live context injection** — A `## Context` section uses `!` syntax to inject runtime values:
  ```
  - Current jj status: !`jj status`
  - Current change: !`jj log -r @ --no-graph`
  ```
- **Idempotency** — Commands that modify project state should be safe to re-run.

## Agent conventions

Agents are Markdown files in `agents/` with YAML frontmatter:

```yaml
---
name: code-explorer
description: Deeply analyzes existing codebase features …
tools: Glob, Grep, LS, Read, NotebookRead, WebFetch, TodoWrite, WebSearch, KillShell, BashOutput
model: sonnet
color: yellow
---
```

Fields:

| Field | Required | Notes |
|---|---|---|
| `name` | yes | Kebab-case identifier |
| `description` | yes | Often multi-line with `<example>` blocks for trigger matching |
| `model` | yes | `opus` for high-stakes review, `sonnet` for exploration/architecture, `inherit` for lighter specialized agents |
| `color` | yes | Visual grouping (green, yellow, red, cyan, pink) |
| `tools` | no | Explicit list restricts available tools; omit to inherit defaults |

## Setup/config commands

Commands that bootstrap project configuration (e.g. `project-setup`) must be fully idempotent:

- **Marker comments** for CLAUDE.md sections:
  ```
  <!-- jj-project-setup:start -->
  …content…
  <!-- jj-project-setup:end -->
  ```
  If markers exist, replace content between them. If CLAUDE.md exists without markers, prepend. If no CLAUDE.md, create it.

- **`jq` deep-merge** for `.claude/settings.local.json` — concatenate and deduplicate arrays (`allow`, `deny`), merge objects recursively, preserve unrelated keys.

- **`${CLAUDE_PLUGIN_ROOT}`** for referencing scripts and templates in `plugin.json` so paths resolve from the plugin's installed location.

## Review agents

- **Confidence scoring** — Issues are rated 0–100. Only issues with confidence >= 80 are reported. The shared rubric: 0 = false positive, 25 = uncertain, 50 = nitpick, 75 = verified real issue, 100 = certain.

- **Multi-agent orchestration** — Review commands launch multiple specialized agents (code-reviewer, silent-failure-hunter, pr-test-analyzer, etc.) either sequentially or in parallel. Agent selection is conditional on what changed in the PR. Results are aggregated into priority tiers (Critical / Important / Suggestions).
