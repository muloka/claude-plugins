---
description: "Execute a plan using wave-based parallel orchestration with spec review gates"
argument-hint: "[plan-file]"
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Execute the fan-flames skill to orchestrate parallel subagent execution across isolated jj workspaces.

**Load the skill first:**

Use the Skill tool to invoke `workspace-jj:fan-flames`, then follow it exactly.

**Input:** If `$ARGUMENTS` contains a plan file path, read it and use it as the plan document. Otherwise, ask the user for a plan document or ad-hoc task list.
