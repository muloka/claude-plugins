---
name: warn-raw-git
enabled: true
event: bash
action: warn
pattern: (^|[;&|]\s*)git\s
---

**Raw git command detected.** This project uses jj (Jujutsu) as its VCS.

Use jj equivalents instead:
- `git status` → `jj status`
- `git diff` → `jj diff`
- `git log` → `jj log`
- `git add` / `git commit` → `jj commit` or `jj describe` + `jj new`
- `git push` → `jj git push`
- `git fetch` → `jj git fetch`

The only allowed git commands are `jj git` subcommands and `gh` CLI.
