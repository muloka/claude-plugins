---
name: warn-git-internals
enabled: true
event: bash
action: warn
pattern: (\.git/|\.git\b|git\s+config|git\s+rev-parse)
---

**Git internals access detected.** This project uses jj (Jujutsu).

Avoid accessing `.git/` directly or using git plumbing commands. Use jj equivalents:
- `git rev-parse HEAD` → `jj log -r @ --no-graph -T commit_id`
- `git config` → `jj config list` / `jj config set`
- `ls .git/` → not needed; use `jj root` to find the repo root
- `git remote -v` → `jj git remote list`
