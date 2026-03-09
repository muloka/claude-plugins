---
description: List all jj workspaces with JSON output
allowed-tools: Bash(jj:*)
---

## Context

- Active workspaces (JSON): !`jj workspace list --no-pager -T 'json(self) ++ "\n"'`

## Your Task

Present the workspace list to the user in a clear summary. For each workspace, show:

- **Name**: The workspace name
- **Change ID**: The target change ID
- **Description**: The change description (or "(no description)" if empty)
- **Author**: Who created it

If there are multiple workspaces, note which ones may be stale (no recent description or activity).
