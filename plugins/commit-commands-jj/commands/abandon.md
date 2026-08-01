---
allowed-tools: Bash(jj abandon:*), Bash(jj log:*), Bash(jj status:*), Bash(jj diff:*)
description: Discard a jj change (current or specified revision)
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Current diff stats: !`jj diff --stat`
- Current status: !`jj status`

## Git → jj translation

| Git | jj |
|---|---|
| `git reset --hard HEAD~1` | `jj abandon` |
| `git checkout -- .` | `jj abandon` (then jj creates a new empty change) |
| `git diff --stat` | `jj diff --stat` |
| `git status` | `jj status` |

## Your task

In jj, `jj abandon` discards a change entirely. Descendants are rebased onto its parent. If you abandon the current working copy change, jj automatically creates a new empty change in its place.

1. **Capture the restore point before abandoning anything:**
   ```bash
   jj op log -n 1 --no-graph -T 'id.short()'
   ```
   `jj op log` snapshots the working copy before it reports, so this id already
   covers the current state. Do **not** add `--ignore-working-copy` — it skips
   that snapshot and returns a restore point predating the latest edits.
2. Check if the current change has modifications (from the diff stats/status above)
   - If it does, warn the user that the change has uncommitted work that will be lost
3. Run `jj abandon`
   - If the user specified a revision, run `jj abandon <revision>` instead
4. Show the result: `jj log --limit 5 --no-graph -T 'json(self) ++ "\n"'` and `jj status`
5. **Hand back the id from step 1, not a bare `jj undo`:**
   ```
   If you want it back: jj op restore <id>
   ```

Notes:
- Abandoning a change does NOT delete its content from the op log, so it stays
  recoverable — but **say how with the captured id, not with bare `jj undo`.**
  `jj undo` is *sequential*: it reverses whatever the most recent operation
  happens to be. Immediately after the abandon that is the abandon, so it works.
  Let one ordinary command run in between — a `jj describe`, anything — and it
  reverses that instead, **reporting success while the abandoned work stays
  gone.** `jj op restore <id>` names the target and says the same thing however
  much has happened since. `/undo` is safe to point at because it runs
  `jj op revert <op-id>` with an explicit id; bare `jj undo` is not the same thing
- If the abandoned change carried a bookmark that had been **pushed**, the remote
  still holds its copy — `jj abandon` does not touch the remote. Only a later
  `jj git push --deleted` removes it, and recovering from *that* additionally
  needs `jj op restore <id> --what repo`, because the bare form restores
  remote-tracking refs and leaves jj believing the remote still has the branch
- Descendants of the abandoned change are rebased onto its parent
- If you abandon the working copy change (`@`), jj creates a new empty change automatically
- To abandon multiple changes, use a revset: `jj abandon <revset>`

You have the capability to call multiple tools in a single response. Perform the abandon using a single message. Do not use any other tools or do anything else. Do not send any other text or messages besides these tool calls.
