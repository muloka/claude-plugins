# agent-helpers-jj

Machine-level jj (Jujutsu) query shortcuts for agents. Four read-only shell
functions, each wrapping `jj --ignore-working-copy …`, so an agent orienting
inside a jj repo never writes a working-copy snapshot to the shared operation
log — the serialization point that concurrent workspaces (e.g. kaisen)
would otherwise race on.

| Function | Output | Purpose |
|---|---|---|
| `jjctx` | one JSON object | current change (orientation) |
| `jjstack` | JSONL | local changes ahead of trunk |
| `jjconflicts` | exit code | 0 = clean, 1 = conflicts (printed), >1 = jj error |
| `jjcheckpoint` | short op id | restore point — pass to `jj op restore` later |

The first three are **structural** queries — they read committed / op-log state,
where `--ignore-working-copy` is strictly correct, and they may be polled
repeatedly from inside concurrent workspaces without perturbing the shared op
log. Two working-copy helpers (`jjclean`, `jjfiles`) were considered and cut:
under `--ignore-working-copy` they report the last *snapshot*, not live edits,
so they'd give stale answers to "am I clean / what changed?". For that, use
plain `jj status` / `jj diff`.

**`jjcheckpoint` is the deliberate exception: it snapshots.** It is not a query
— its output is a restore target, and kaisen restores to it to abort a run. With
`--ignore-working-copy` it returned the op *before* the working copy was
snapshotted, so the id named a state predating any edit not yet snapshotted, and
`Write`/`Edit` do not snapshot. Restoring to such an id dropped those edits
silently. Measured and pinned in `tests/test-jj-agent-helpers.sh`; the same trap
is documented in `commit-commands-jj`'s `/finish` and `/abandon`.

Take it immediately before anything destructive, and recover with
`jj op restore <id>` — adding `--what repo` if the discard also deleted a pushed
bookmark, otherwise jj keeps believing the remote still has it.

## Install

```
/agent-helpers-setup
```

This is a **machine-level, one-time** install (not per-project). It:
1. copies the helper script to `~/.config/jj-agent-helpers/jj-agent-helpers.sh`;
2. adds a `source` line to `~/.zshrc` (consent-gated);
3. adds a one-line catalog to `~/.claude/CLAUDE.md` so agents know the helpers exist;
4. allowlists the four helpers in `~/.claude/settings.json` so they run prompt-free.

**Restart Claude Code afterward** — the helpers become callable only once the next
session regenerates its shell snapshot.

Uninstall with `/agent-helpers-remove` (reverses all four steps).

Requires zsh, `jj`, and [`jq`](https://jqlang.github.io/jq/) (used by the
installer to edit `~/.claude/settings.json`). Bash shells are not supported in
this version.
