# jj Agent-Safety and jj-Native Enhancements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use workspace-jj:fan-flames (per CLAUDE.md override of superpowers:subagent-driven-development) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks 1, 3, 4, and 5 all modify `fan-flames.md` — inline execution recommended.

**Goal:** Port three safety practices identified by comparing against the netresearch jujutsu-workflow skill (interactive-command footguns, PreCompact snapshot hook, divergent-change handling) and adopt four jj-native enhancements from the 0.43 feature evaluation (op-restore run rollback, evolog fix-delta re-reviews, an `/absorb` command, and `push --change` quick-path notes).

**Architecture:** All prose/config edits plus one new command file, no scripts. Tasks 1–3 are the netresearch-inspired hardening. Task 4 records the run's starting operation ID in the fan-flames ledger, enabling atomic whole-run rollback via `jj op restore`. Task 5 points fix-loop re-reviews at the amendment delta via `jj evolog -p`. Task 6 adds `/absorb` to commit-commands-jj. Task 7 documents the `jj git push --change` quick path in the two push commands.

**Tech Stack:** Markdown only. jj for VCS.

**Attribution note:** These are ideas adapted from netresearch/jujutsu-workflow-skill (MIT AND CC-BY-SA-4.0). Write all text in this repo's own words — do not copy their prose verbatim.

## Global Constraints

- **No raw git commands anywhere** — jj equivalents only.
- **Non-interactive rule being enforced:** bare `jj describe`/`commit`/`squash` (no `-m`), `jj resolve` (bare or with a file), `jj diffedit`, and `jj split` without paths all launch editors/TUIs that hang agents. After this plan, no live plugin file may instruct an agent to run any of those forms; interactive forms may only be mentioned as explicitly human-only.
- **Conflict resolution method (canonical wording):** edit the conflict markers in the file to the intended content, then verify with `jj resolve --list` (should be empty). Interactive `jj resolve` is human-only.
- **Snapshot-hook exception:** the PreCompact hook deliberately OMITS `--ignore-working-copy` — its entire purpose is to force a snapshot. This is the documented exception to the background-tooling rule from the 0.43 audit.
- **Commit convention:** conventional commits, `jj describe -m "…"` then `jj new`.

---

### Task 1: Fan-flames agent-safety sweep

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (dispatch prompt ~line 297; selective rejection ~line 704; fan-in conflicts ~line 748; conflict reference ~line 828)

**Interfaces:**
- Consumes: nothing.
- Produces: the canonical conflict-resolution wording (see Global Constraints), reused verbatim in both conflict sections.

- [ ] **Step 1: Add the non-interactive rule to the dispatch prompt**

In `plugins/workspace-jj/skills/fan-flames.md`, in the FAN OUT dispatch template, directly after the block:

```
    CRITICAL: You MUST NOT use ANY raw git commands — not even for context
    discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.).
    The only exceptions are `jj git` subcommands and `gh` CLI.
```

insert:

```
    CRITICAL: Use only non-interactive jj forms — interactive commands hang
    you. Always pass -m to describe/commit/squash. Never run bare
    `jj describe`, `jj resolve`, `jj diffedit`, `jj split` without paths, or
    any command that opens an editor or TUI. To resolve a conflict, edit the
    conflict markers in the file, then verify with `jj resolve --list`.
```

- [ ] **Step 2: Fix the selective-rejection diffedit instruction**

Replace:

````markdown
For partial acceptance (keep some changes from a rejected task):

```bash
jj diffedit -r <change-id>        # remove unwanted parts from the diff
```

Or split by file path, then abandon the unwanted half:
````

with:

```markdown
For partial acceptance (keep some changes from a rejected task), split by
file path, then abandon the unwanted half (`jj diffedit` also works but is
interactive — human-only, never for agents):
```

(The `jj split -r <change-id> paths/to/keep` block that follows stays as the method.)

- [ ] **Step 3: Fix the fan-in conflict instruction**

Replace:

```markdown
If conflicts exist:
- Report them clearly with file paths
- Ask user: resolve now, skip this task, or abandon the merge
- If user wants to resolve: use `jj resolve` to handle each conflict
```

with:

```markdown
If conflicts exist:
- Report them clearly with file paths
- Ask user: resolve now, skip this task, or abandon the merge
- If the user wants it resolved: edit the conflict markers in each file to
  the intended content, then verify with `jj resolve --list` (should be
  empty). For take-one-side resolutions, `jj resolve --tool :ours <path>`
  (or `:theirs`) is non-interactive and safe. Never run `jj resolve` bare
  or with only a file argument — that launches an interactive merge tool
```

- [ ] **Step 4: Fix the conflict-handling reference**

Replace:

```markdown
- Use `jj resolve --list` to see conflicted files
- Use `jj resolve <file>` to resolve interactively
```

with:

```markdown
- Use `jj resolve --list` to see conflicted files
- Resolve by editing the conflict markers in the file to the intended
  content — or `jj resolve --tool :ours <path>` / `:theirs` for
  take-one-side cases — then re-check `jj resolve --list` (interactive
  `jj resolve` is human-only — it hangs agents)
```

- [ ] **Step 5: Verify**

```bash
grep -n "jj diffedit\|use \`jj resolve\`\|resolve interactively" plugins/workspace-jj/skills/fan-flames.md
grep -c "non-interactive jj forms" plugins/workspace-jj/skills/fan-flames.md
```

Expected: first grep returns only the human-only diffedit mention from Step 2 (no bare instructions); second returns 1.

- [ ] **Step 6: Commit**

```bash
jj describe -m "fix(fan-flames): eliminate interactive-command footguns

Three instructions launched editors/merge tools that hang agents: jj
diffedit for partial acceptance, bare jj resolve in fan-in conflicts, and
'jj resolve <file> interactively' in the conflict reference. All now use
the non-interactive method (edit markers, verify with resolve --list;
split+abandon for partial acceptance), and dispatch prompts carry a
non-interactive-forms rule. Adapted from netresearch/jujutsu-workflow-skill's
agent-safety findings."
jj new
```

---

### Task 2: PreCompact snapshot hook in /project-setup

**Files:**
- Modify: `plugins/project-setup-jj/commands/project-setup.md` (settings merge Step 3, SessionStart JSON block ~line 38; summary list ~line 170)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the PreCompact hook to the settings merge**

In `plugins/project-setup-jj/commands/project-setup.md`, replace the SessionStart hook JSON block:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "<project-root>/.claude/scripts/jj-session-start.sh",
            "async": false
          }
        ]
      }
    ]
  }
}
```

with:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume|clear|compact",
        "hooks": [
          {
            "type": "command",
            "command": "<project-root>/.claude/scripts/jj-session-start.sh",
            "async": false
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "jj status >/dev/null 2>&1 || true"
          }
        ]
      }
    ]
  }
}
```

Directly below the JSON block, add this explanation:

```markdown
The PreCompact hook forces a working-copy snapshot (and an operation-log
entry) immediately before context compaction, so `jj undo` / `jj op restore`
can always reach the pre-compaction state even if the session's memory of
recent edits is lost. It deliberately omits `--ignore-working-copy` — the
snapshot is the point.
```

- [ ] **Step 2: Update the setup summary**

In the same file, find the summary line:

```markdown
- SessionStart hook script copied to `.claude/scripts/jj-session-start.sh`
```

and add after it:

```markdown
- PreCompact hook snapshots the working copy before context compaction
```

- [ ] **Step 3: Verify**

```bash
grep -n "PreCompact" plugins/project-setup-jj/commands/project-setup.md
```

Expected: hits in the JSON block, the explanation, and the summary. Note in the commit that existing projects pick this up by re-running `/project-setup` (the settings merge is idempotent).

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(project-setup): PreCompact snapshot hook

jj snapshots only when a jj command runs — edits between commands live
only on disk. A PreCompact hook running jj status guarantees an op-log
entry right before context compaction, so op restore can always reach the
pre-compaction state. Existing projects: re-run /project-setup. Adapted
from netresearch/jujutsu-workflow-skill's hook recipe."
jj new
```

---

### Task 3: Divergent-change guidance

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (after the `### Recovery: Missing Change IDs` section, ~line 500)
- Modify: `plugins/workspace-jj/README.md` (Side Threads section, after the "Each workspace has its own working copy…" paragraph)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add a Divergent Changes subsection to fan-flames COLLECT**

In `plugins/workspace-jj/skills/fan-flames.md`, immediately after the `### Recovery: Missing Change IDs` section (after the line `If multiple matches, use the most recent. If no matches, the subagent likely never created any changes — treat as BLOCKED.`), insert:

```markdown
### Divergent Changes (`change_id??`)

A change ID printed with a `??` suffix means the same change has two
commits — divergence. In fan-flames this happens if anything rewrites a
change that a live task workspace still holds as its `@` (e.g. the
orchestrator running `jj edit`/`jj squash` on a task's change before that
workspace is forgotten, or two fix subagents amending the same change).

- Detect: `jj log -r '<change-id>'` shows both commits when divergent
- Fix: inspect both sides, then `jj abandon <unwanted-COMMIT-id>` (commit
  ID, not change ID — the change ID is ambiguous while divergent)
- Prevent: never rewrite a task's change while its workspace is still
  registered; fix subagents work only in their own task's workspace
```

- [ ] **Step 2: Add the one-line warning to the README**

In `plugins/workspace-jj/README.md`, replace:

```markdown
Each workspace has its own working copy (`@`), so tabs never affect each other; all changes remain visible in the shared `jj log` from anywhere.
```

with:

```markdown
Each workspace has its own working copy (`@`), so tabs never affect each other; all changes remain visible in the shared `jj log` from anywhere. One rule: never `jj edit` (or otherwise rewrite) a change that another workspace has checked out as its `@` — that creates a divergent change (`change_id??`, two commits for one change). Recover by abandoning the unwanted commit by its commit ID.
```

- [ ] **Step 3: Verify**

```bash
grep -c "??" plugins/workspace-jj/skills/fan-flames.md plugins/workspace-jj/README.md
grep -n "Divergent Changes" plugins/workspace-jj/skills/fan-flames.md
```

Expected: `??` appears in both files; the new subsection sits inside Phase 3 (COLLECT), before Workspace Lifecycle.

- [ ] **Step 4: Commit**

```bash
jj describe -m "docs(workspace-jj): divergent-change (change_id??) guidance

Documents the divergence failure mode (rewriting a change another
workspace holds as @), detection, recovery by commit ID, and prevention —
in fan-flames COLLECT and the README side-threads section. Adapted from
netresearch/jujutsu-workflow-skill's parallel-agents field notes."
jj new
```

---

### Task 4: Ledger start-op and atomic run rollback

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Durable Progress ledger example + Prepare Artifacts init block + new Aborting a Run subsection)

**Interfaces:**
- Consumes: nothing.
- Produces: the `start-op: <op-id>` ledger header field; the Aborting a Run protocol referenced by escalation guidance.

- [ ] **Step 1: Add start-op to both ledger header sites**

In `plugins/workspace-jj/skills/fan-flames.md`, in the Durable Progress example, replace:

```
# fan-flames ledger — plan: docs/plans/foo-plan.md — parent: xyzabc12
```

with:

```
# fan-flames ledger — plan: docs/plans/foo-plan.md — parent: xyzabc12 — start-op: 4279dc009e64
```

And in the Prepare Artifacts ledger-init block, replace:

```
   # fan-flames ledger — plan: <plan path or "ad-hoc"> — parent: <change-id of @->
```

with:

```
   # fan-flames ledger — plan: <plan path or "ad-hoc"> — parent: <change-id of @-> — start-op: <jj op log -n1 --no-graph -T 'id.short()'>
```

- [ ] **Step 2: Add the Aborting a Run subsection**

In the Durable Progress and Resume section, immediately before `### Resume Check (at skill start, before PLAN)`, insert:

````markdown
### Aborting a Run (atomic rollback)

The ledger header's `start-op` is the run's whole-repo checkpoint. If the
user aborts a run (or fix loops fail beyond repair), the entire run — every
workspace add, squash, and abandon — can be undone atomically:

```
jj op restore <start-op-id>
```

This restores the repo to the exact state before PLAN ran. The artifacts
directory lives outside the repo, so briefs, reports, and the ledger
survive — append `run: aborted (restored to <start-op-id>)` to the ledger
afterward so the resume check doesn't misread the run as interrupted.
Only use this for full aborts: it also reverts any changes the run
legitimately merged.
````

- [ ] **Step 3: Verify**

```bash
grep -c "start-op" plugins/workspace-jj/skills/fan-flames.md
grep -n "Aborting a Run" plugins/workspace-jj/skills/fan-flames.md
```

Expected: `start-op` ≥ 3 (two headers + subsection); the subsection sits inside Durable Progress before the Resume Check.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(fan-flames): atomic run rollback via ledger start-op

The ledger header now records the operation ID at run start; jj op restore
<start-op> undoes an entire aborted run (workspace adds, squashes,
abandons) in one command. Artifacts live outside the repo and survive."
jj new
```

---

### Task 5: Fix-delta re-reviews via evolog

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md` (Fix Loop item 3)

**Interfaces:**
- Consumes: Fix Loop item numbering as amended by Task 1 of the SDD-parity plan (already merged — current item 3 is `Re-dispatch reviewer for affected files only`).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Point re-reviews at the amendment delta**

In the Fix Loop list, replace:

```markdown
3. Re-dispatch reviewer for affected files only
```

with:

```markdown
3. Re-dispatch reviewer scoped to the fix delta: fix subagents amend in
   place, so `jj evolog -r <change-id> -p --limit 2` shows exactly what the
   fix changed. Name that command in the re-review prompt as the reviewer's
   primary view (with the original findings for context) — re-reviews judge
   the amendment, not the whole task again
```

- [ ] **Step 2: Verify**

```bash
grep -n "evolog" plugins/workspace-jj/skills/fan-flames.md
```

Expected: one hit inside the Fix Loop.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(fan-flames): re-reviews scoped to the fix delta via evolog

Fix subagents amend in place, so jj evolog -r <id> -p shows the amendment
diff — re-reviewers judge what changed since the prior review instead of
re-reading whole files."
jj new
```

---

### Task 6: /absorb command

**Files:**
- Create: `plugins/commit-commands-jj/commands/absorb.md`

**Interfaces:**
- Consumes: the command-file conventions from `plugins/commit-commands-jj/commands/squash.md` (frontmatter, CRITICAL git block, JSON context, translation table).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Create the command file**

Create `plugins/commit-commands-jj/commands/absorb.md` with exactly:

```markdown
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
```

- [ ] **Step 2: Verify**

```bash
head -4 plugins/commit-commands-jj/commands/absorb.md
grep -c "jj absorb" plugins/commit-commands-jj/commands/absorb.md
```

Expected: frontmatter present; ≥ 3 mentions.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(commit-commands): /absorb command

jj absorb distributes working-copy edits into the mutable ancestors that
last touched those lines — the stacked-changes fixup tool. Same JSON-context
command format as /squash."
jj new
```

---

### Task 7: push --change quick-path notes

**Files:**
- Modify: `plugins/commit-commands-jj/commands/commit-push-pr.md` (step 5)
- Modify: `plugins/commit-commands-jj/commands/finish.md` (bookmark-creation step)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the note to commit-push-pr**

In `plugins/commit-commands-jj/commands/commit-push-pr.md`, replace:

```markdown
5. Push: `jj git push --bookmark <name>`
```

with:

```markdown
5. Push: `jj git push --bookmark <name>` (if the user asked for a quick push and no descriptive name matters, `jj git push --change @-` generates and pushes a `push-<change-id>` bookmark in one step — skip steps 3–4)
```

- [ ] **Step 2: Add the note to finish**

In `plugins/commit-commands-jj/commands/finish.md`, replace:

````markdown
   If no bookmark: create one from the change description:
   ```bash
   jj bookmark create <kebab-case-name> -r <target>
   ```
````

with:

````markdown
   If no bookmark: create one from the change description:
   ```bash
   jj bookmark create <kebab-case-name> -r <target>
   ```
   (Descriptive names make better PR branches. Only if the user explicitly
   wants a quick anonymous push: `jj git push --change <target>` generates a
   `push-<change-id>` bookmark and pushes it in one step.)
````

- [ ] **Step 3: Verify**

```bash
grep -rn "push --change" plugins/commit-commands-jj/commands/
```

Expected: one hit in each of the two files.

- [ ] **Step 4: Commit**

```bash
jj describe -m "docs(commit-commands): note jj git push --change quick path

For pushes where no descriptive branch name matters, push --change
generates and pushes a push-<change-id> bookmark in one step. Named
bookmarks stay the default for PR branches."
jj new
```

---

## Deliberately not ported

- `--no-pager` sweep / `ui.paginate never` — jj's pager only engages on a TTY, and Claude Code's Bash tool is not a TTY; the risk their skill guards against doesn't apply in this harness. Revisit only if plugins target other harnesses.
- `verify_handoff.sh`-style hard gate script for `/finish` — worthwhile but separate scope (item 4 of the comparison).
- Eval suite (`claude plugin eval` cases) — right long-term practice, separate initiative (item 5).
- Their git-interop "read-only git allowed" stance — this repo's `block-raw-git.sh` hook is deliberately stricter (blocks all git); keeping it.
- From the jj-features evaluation: `jj fix` formatting gate (needs per-repo `fix.tools` config design — project-setup scope, later), sparse workspaces for fan-flames (opt-in flag, test suites usually need the full tree), and `jj run` for the test gate (first release, immature) — all in the revisit bucket.

## Verification (whole branch)

1. `grep -rn "jj diffedit\|jj resolve" plugins/ --include="*.md" | grep -v "resolve --list"` — every remaining hit is either explicitly human-only or a permissions allowlist entry
2. `plugins/workspace-jj/tests/test-fan-flames-scripts.sh` — still 15/15 (regression; untouched)
3. `grep -c "start-op" plugins/workspace-jj/skills/fan-flames.md` ≥ 3; `grep -rn "push --change" plugins/commit-commands-jj/commands/` hits exactly 2 files
4. Read the edited regions once for coherence; fan-flames.md growth from Tasks 1+3+4+5 stays under ~60 lines
