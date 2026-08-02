<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->
**jj query helpers** (structural, read-only; use `--ignore-working-copy`, safe under concurrent workspaces): `jjctx` current change (one JSON object) · `jjstack` local changes vs trunk (JSONL) · `jjconflicts` (exit 0 = clean, 1 = conflicts)

**`jjcheckpoint`** — op id to hand to `jj op restore` later. Unlike the three above it **does** snapshot the working copy, deliberately: a restore point that excluded your unsnapshotted edits would lose them silently on restore. Take it immediately before anything destructive; recover with `jj op restore <id>` (add `--what repo` if the discard also deleted a pushed bookmark, or jj will believe the remote still has it).
<!-- END jj-agent-helpers -->
