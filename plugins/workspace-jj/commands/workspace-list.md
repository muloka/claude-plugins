---
description: List all jj workspaces with JSON output
allowed-tools: Bash(jj:*)
---

## Context

- Active workspaces (JSON): !`jj workspace list --ignore-working-copy --no-pager -T 'json(self) ++ "\n"'`
- Workspace roots: !`jj workspace list --ignore-working-copy --no-pager -T 'self.name() ++ ": " ++ self.root() ++ "\n"'`

## Your Task

Present the workspace list to the user in a clear summary. For each workspace, show:

- **Name**: The workspace name
- **Root**: The absolute path to the workspace directory (from the roots list)
- **Change ID**: The target change ID
- **Description**: The change description (or "(no description)" if empty)
- **Author**: Who created it

If a root shows an `<Error: Failed to resolve workspace root: ...>` entry, the
recorded directory no longer exists (moved or deleted) — flag that workspace
as stale and suggest `jj workspace forget <name>` (or `/clean_stale`).

If there are multiple workspaces, note which ones may be stale (no recent description or activity).
