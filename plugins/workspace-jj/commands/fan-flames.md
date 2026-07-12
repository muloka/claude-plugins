---
description: "Execute a plan using wave-based parallel orchestration with spec review gates"
argument-hint: "[plan-file] [--skip-review] [--merge-order auto|task-1,task-2,...]"
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands and `gh` CLI.**

# Fan-Flames

Invoke the `workspace-jj:fan-flames` skill and follow it exactly — the skill
is the single source of truth for the fan-flames workflow (phases, prompts,
artifacts, ledger, and flags).

Arguments to pass through: $ARGUMENTS

- **plan-file** — path to a plan document with numbered tasks. If no plan
  file is given, ask the user for a plan document or an ad-hoc task list.
- **--skip-review** — skip the REVIEW phase (see the skill's Flags table)
- **--merge-order** — `auto` (default) or an explicit task order
