---
name: require-jj-workflow
enabled: true
event: stop
action: warn
conditions:
  - field: transcript
    operator: not_contains
    pattern: jj new
---

**Reminder:** `jj new` was not detected in this session.

Best practice is to start a fresh change with `jj new` before making edits. This keeps your work isolated and easy to undo.

Workflow:
1. `jj new` — start a fresh change
2. `jj describe -m "..."` — set intent
3. Make your changes
4. `jj diff` — review
5. `jj commit` or proceed to push
