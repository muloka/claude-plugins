# Post-#68/#69 README Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use workspace-jj:fan-flames (per CLAUDE.md override of superpowers:subagent-driven-development). Each task touches exactly one README; all three are independent and run in a single wave.

**Goal:** Audit three plugin READMEs against what their plugins actually ship. Two of them describe behaviour that changed in #68 and #69; the third has never been audited at all.

**Architecture:** Markdown only. One task per plugin directory. Plugin directories are disjoint, so no task can conflict with another.

**Tech Stack:** Markdown. jj for VCS.

## Global Constraints

- **No raw git commands anywhere** — jj equivalents only. The only exceptions are `jj git` subcommands and the `gh` CLI.
- **Non-interactive jj forms only** — always pass `-m` to describe/commit/squash. Never run bare `jj describe`, `jj resolve`, `jj diffedit`, or `jj split` without paths.
- **Audit, don't redesign.** Fix drift between the README and what is on disk. Do not add features, invent components, restructure the document, or rewrite prose that is already accurate.
- **Scope discipline.** Each task modifies exactly one file: its own plugin's README. Never edit another plugin's files, the source components themselves, or shared docs.
- **Evidence over assumption.** Every claim you keep or write must be checked against a file you actually read. If the README documents behaviour, open the command/script/skill and confirm the behaviour matches. A claim that merely *sounds* right is exactly the failure this audit exists to catch.
- **An empty change is a valid result.** If a README is already accurate, change nothing and report that. "No drift found" is a real finding, not a failure — but it must be *verified*, not assumed.

## What "drift" means

For each plugin, the README should satisfy all four:

1. **No missing components** — every command, agent, skill, script, and template that exists on disk and is user-facing is documented.
2. **No phantom components** — nothing documented that no longer exists on disk.
3. **Accurate behaviour** — descriptions, flags, arguments, and examples match what the files actually do.
4. **Accurate names and paths** — command names, file paths, and script names are spelled as they exist.

## Format note

Task headings look like this, and a fenced example must not confuse the extractor:

```markdown
### Task 9: this heading is inside a code fence and is not a real task
```

---

### Task 1: permission-gateway README audit

**Files:**
- Modify: `plugins/permission-gateway/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read every file under `plugins/permission-gateway/` except the README itself: the plugin manifest, every command, every script, every skill or agent, and the test file. This plugin has **never been audited** — it was deliberately excluded from the 2026-07-14 run — so treat every README claim as unverified.

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above. Because nothing here has been checked before, work in both directions deliberately: every component on disk should appear in the README, and every component named in the README should exist on disk.

- [ ] **Step 3: Fix the drift**

Edit `plugins/permission-gateway/README.md` only. Keep the existing structure and voice.

- [ ] **Step 4: Verify**

Confirm the set of components named in the README equals the set on disk, and that every behavioural claim traces to a file you read in Step 1.

---

### Task 2: workspace-jj README vs the post-#68 skill

**Files:**
- Modify: `plugins/workspace-jj/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read `plugins/workspace-jj/skills/fan-flames.md` in full, plus both commands, all four scripts, `skills/fan-flames-wave-reviewer.md`, and both test files (`tests/test-fan-flames-scripts.sh` and the new `tests/test-model-selection-lint.sh`).

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above.

PR #68 changed fan-flames substantially: the REVIEW phase gained a no-test-surface branch, the phase diagram no longer says `cargo test`, the Workspace Integrity Check now compares against a baseline recorded at PLAN rather than assuming an empty `@`, the fix loop re-runs that check and records a pre-fix commit ID, FAN IN's conflict check moved from `jj resolve --list` to `jj log -r 'conflicts()'`, and the ledger gained two event types. Task briefs are now self-contained (the preamble is prepended).

If the README summarises any of that — phases, flags, the diagram, the ledger, behaviour — verify the summary against `skills/fan-flames.md` **as it exists now**. If the README does not summarise something, that is not automatically drift: only criterion 1 (missing *user-facing* components) forces documentation.

- [ ] **Step 3: Fix the drift**

Edit `plugins/workspace-jj/README.md` only. Do **not** edit the skill — the README describes it, not the reverse.

- [ ] **Step 4: Verify**

Confirm the README's account of fan-flames' phases and flags matches `plugins/workspace-jj/skills/fan-flames.md`.

---

### Task 3: commit-commands-jj README vs the post-#69 /finish

**Files:**
- Modify: `plugins/commit-commands-jj/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read every command file under `plugins/commit-commands-jj/commands/` (there are 16) and the one script. Read `commands/finish.md` especially closely — it changed in #69.

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above.

PR #69 rewrote `/finish`'s post-merge cleanup: it now fetches first, verifies trunk actually contains the work before abandoning anything, moves the working copy onto the merged trunk, and deletes the bookmark — plus a note that `gh pr merge --delete-branch` fails in a jj repo.

The README's `/finish` section describes the command in four numbered steps. Decide, with evidence, whether it is now inaccurate (criterion 3) or merely brief. **Being incomplete is not the same as being wrong** — do not pad the README with detail it never claimed to carry. If it is accurate as far as it goes, say so and change nothing.

- [ ] **Step 3: Fix the drift**

Edit `plugins/commit-commands-jj/README.md` only. Keep the existing structure and voice.

- [ ] **Step 4: Verify**

Confirm the set of commands named in the README exactly equals the set of files in `plugins/commit-commands-jj/commands/`, and that the `/finish` description does not contradict `commands/finish.md`.

---

## Verification (whole plan)

1. At most three files changed, one README per plugin.
2. No source component (command, script, skill, agent, template) was modified.
3. For each plugin: the set of components named in the README equals the set on disk.
4. Any task reporting "no drift" verified that claim against the components, rather than assuming it.
