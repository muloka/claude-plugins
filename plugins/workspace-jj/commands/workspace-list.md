---
description: List all jj workspaces with JSON output
allowed-tools: Bash(jj:*), Bash(jq:*)
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands. Use jj equivalents instead (e.g. `jj log`, `jj status`, `jj diff`). The only exceptions are `jj git` subcommands (e.g. `jj git push`) and the `gh` CLI for GitHub operations.**

## Context

- Active workspaces (JSON): !`jj workspace list --ignore-working-copy --no-pager -T 'json(self) ++ "\n"'`
- Workspace roots: !`jj workspace list --ignore-working-copy --no-pager -T 'self.name() ++ ": " ++ self.root() ++ "\n"'`
- Live Claude Code sessions on this machine (name, status, cwd): !`jq -r '[.name,.status,.cwd]|@tsv' ~/.claude/sessions/*.json 2>/dev/null`

## Your Task

Present the workspace list to the user in a clear summary. For each workspace, show:

- **Name**: The workspace name
- **Root**: The absolute path to the workspace directory (from the roots list)
- **Change ID**: The target change ID
- **Description**: The change description (or "(no description)" if empty)
- **Author**: Who created it
- **Session**: See below

### Session occupancy

The sessions list covers **every project on this machine**, not just this one.
Attribute a session to a workspace when its `cwd` is that workspace's root or a
directory under it. That match is also the project filter — a session belonging
to another repository matches no root here and is simply not shown.

Do not match on the session name. Workspace directory names repeat across
projects (the same adjective-verb-noun scheme), so names from a different
repository look exactly like this one's and produce confident wrong answers.

On macOS `/tmp` is a symlink to `/private/tmp`. Treat the two spellings of a path
as the same location when matching.

Report occupancy in three states, and never let two of them look alike:

- **Occupied** — give the session name **verbatim in backticks, never
  abbreviated or reformatted**. The trailing suffix (e.g. `-15`) is part of the
  address. Say this is the name to use when messaging that session.
- **Unoccupied** — no session matched. Flag it. An unoccupied workspace holding
  a non-empty change is orphaned work nobody is watching, which is the most
  useful thing this column surfaces.
- **Unknown** — the sessions context line was empty or errored. Say occupancy
  could not be determined. Do **not** report those workspaces as unoccupied.

Close the summary with: this is a point-in-time read. A session that started
after the command ran does not appear, so an unoccupied workspace means "no
session was seen just now", never "safe to disturb".

### Stale workspaces

If a root shows an `<Error: Failed to resolve workspace root: ...>` entry, the
recorded directory no longer exists (moved or deleted) — flag that workspace
as stale and suggest `jj workspace forget <name>` (or `/clean_stale`). A stale
workspace has no resolvable root, so it will also show as unoccupied; that is
correct, since nothing can run in a directory that is gone.

If there are multiple workspaces, note which ones may be stale (no recent description or activity).
