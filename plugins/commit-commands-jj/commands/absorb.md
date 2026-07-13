---
allowed-tools: Bash(jj absorb:*), Bash(jj log:*), Bash(jj status:*), Bash(jj diff:*)
description: Absorb working-copy changes into the ancestor changes that last touched those lines
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Mutable ancestors (JSON): !`jj log -r 'mutable() & ::@-' --limit 10 --no-graph -T 'json(self) ++ "\n"'`
- Changed files (JSON): !`jj diff -T '"{ \"path\": " ++ self.path().display().escape_json() ++ ", \"status\": " ++ self.status().escape_json() ++ " }\n"'`
- Current status: !`jj status`

## Git → jj translation

| Git | jj |
|---|---|
| `git absorb` (plugin) | `jj absorb` (built in) |
| `git commit --fixup X` + `git rebase -i --autosquash` | `jj absorb` |

## Your task

`jj absorb` distributes the working copy's edits into the mutable ancestor
changes that last touched those lines — the fix for "I amended three stacked
changes in one sitting."

1. If the current change has no diff, report "nothing to absorb" and stop
2. Run `jj absorb` (optionally `jj absorb <paths>` if the user scoped it, or
   `--into <revset>` to restrict target changes)
3. Report which changes absorbed what, from the command's output
4. If edits remain in `@` afterward, report them — lines that no single
   ancestor last touched are left behind by design; suggest `/squash` or a
   manual `jj squash --into <rev>` for those
5. Verify: `jj status` and `jj log --limit 5` to confirm the result
