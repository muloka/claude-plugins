# Plugin README Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use workspace-jj:fan-flames (per CLAUDE.md override of superpowers:subagent-driven-development). Each task touches exactly one README; all five are independent and run in a single wave.

**Goal:** Audit each plugin's README against that plugin's actual commands, agents, scripts, skills, and templates, and fix any drift. READMEs have accumulated drift as plugins gained and lost components across recent PRs.

**Architecture:** Markdown only. One task per plugin directory. Plugin directories are disjoint, so no task can conflict with another.

**Tech Stack:** Markdown. jj for VCS.

## Global Constraints

- **No raw git commands anywhere** — jj equivalents only. The only exceptions are `jj git` subcommands and the `gh` CLI.
- **Non-interactive jj forms only** — always pass `-m` to describe/commit/squash. Never run bare `jj describe`, `jj resolve`, `jj diffedit`, or `jj split` without paths.
- **Audit, don't redesign.** Fix drift between the README and what is on disk. Do not add new features, invent components, restructure the document, or rewrite prose that is already accurate.
- **Scope discipline.** Each task modifies exactly one file: its own plugin's README. Never edit another plugin's files, the source components themselves, or shared docs.
- **Evidence over assumption.** Every claim you keep or write must be checked against a file you actually read. If the README documents behavior, open the command/script and confirm the behavior matches.

## What "drift" means

For each plugin, the README should satisfy all four:

1. **No missing components** — every command, agent, skill, script, and template that exists on disk and is user-facing is documented.
2. **No phantom components** — nothing documented that no longer exists on disk.
3. **Accurate behavior** — descriptions, flags, arguments, and examples match what the files actually do.
4. **Accurate names and paths** — command names, file paths, and script names are spelled as they exist.

---

### Task 1: agent-helpers-jj README audit

**Files:**
- Modify: `plugins/agent-helpers-jj/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read every file under `plugins/agent-helpers-jj/` except the README itself: the plugin manifest, both commands, both scripts, the template, and both test files. The scripts define the actual helper functions (`jjctx`, `jjstack`, `jjconflicts`, `jjcheckpoint`) — their real behavior, flags, and output shape are the ground truth.

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above. Pay particular attention to the helper functions' documented output and flags: this plugin was changed twice recently (PRs #66 and #67), and the README may describe an earlier shape. `--ignore-working-copy` handling in particular is worth verifying against the script.

- [ ] **Step 3: Fix the drift**

Edit `plugins/agent-helpers-jj/README.md` only. Keep the existing structure and voice.

- [ ] **Step 4: Verify**

Re-read your edited README start to finish and confirm every factual claim traces to a file you read in Step 1.

---

### Task 2: commit-commands-jj README audit

**Files:**
- Modify: `plugins/commit-commands-jj/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read every file under `plugins/commit-commands-jj/` except the README itself. There are 16 command files and one script. For each command, note its name, its `description` frontmatter, and what it actually instructs.

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above. This is the largest README in the repo (~549 lines) and the plugin most recently gained commands — `/absorb` was added in PR #64, and `commit-push-pr` and `finish` gained `jj git push --change` notes. Confirm every one of the 16 commands is documented and that none are documented that don't exist.

- [ ] **Step 3: Fix the drift**

Edit `plugins/commit-commands-jj/README.md` only. Keep the existing structure and voice. If the README organizes commands into sections or tables, place any additions where they belong rather than appending.

- [ ] **Step 4: Verify**

Confirm the set of commands named in the README exactly equals the set of files in `plugins/commit-commands-jj/commands/`, with no extras and no omissions.

---

### Task 3: peer-review-jj README audit

**Files:**
- Modify: `plugins/peer-review-jj/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read every file under `plugins/peer-review-jj/` except the README itself: the manifest, the `change-reviewer` agent, the `peer-review` command, both scripts, and both skills (`receiving-change-review`, `requesting-change-review`).

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above. The README is short (~47 lines) relative to the number of components, so missing components are the likeliest drift — confirm both skills, the agent, and both scripts are represented if they are user-facing.

- [ ] **Step 3: Fix the drift**

Edit `plugins/peer-review-jj/README.md` only. Keep the existing structure and voice.

- [ ] **Step 4: Verify**

Re-read your edited README start to finish and confirm every factual claim traces to a file you read in Step 1.

---

### Task 4: project-setup-jj README audit

**Files:**
- Modify: `plugins/project-setup-jj/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read every file under `plugins/project-setup-jj/` except the README itself: the manifest, all three commands, all six scripts, and the test file. The `project-setup` command file describes the hooks it installs — that is ground truth for what the README should say setup does.

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above. PR #64 added a `PreCompact` snapshot hook to the `project-setup` command; verify the README's account of which hooks get installed matches the command file.

- [ ] **Step 3: Fix the drift**

Edit `plugins/project-setup-jj/README.md` only. Keep the existing structure and voice.

- [ ] **Step 4: Verify**

Confirm the hooks and scripts the README says setup installs match what `plugins/project-setup-jj/commands/project-setup.md` actually installs.

---

### Task 5: workspace-jj README audit

**Files:**
- Modify: `plugins/workspace-jj/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Inventory what exists**

Read every file under `plugins/workspace-jj/` except the README itself: the manifest, both commands (`fan-flames`, `workspace-list`), all four scripts (`fan-flames-artifacts`, `fan-flames-task-brief`, `jj-workspace-create.sh`, `jj-workspace-remove.sh`), both skills (`fan-flames.md`, `fan-flames-wave-reviewer.md`), and the test file.

- [ ] **Step 2: Audit the README against that inventory**

Check the README against all four drift criteria in "What drift means" above. The `fan-flames` skill was substantially changed in PRs #64 and #65 (ledger `start-op` and run rollback, evolog-scoped fix re-reviews, divergent-change guidance, model selection). If the README summarizes the skill's phases, flags, or behavior, verify that summary against `skills/fan-flames.md` as it exists now.

- [ ] **Step 3: Fix the drift**

Edit `plugins/workspace-jj/README.md` only. Do not edit the skill — the README describes it, not the reverse.

- [ ] **Step 4: Verify**

Confirm the README's account of fan-flames' flags and phases matches `plugins/workspace-jj/skills/fan-flames.md`.

---

## Verification (whole plan)

1. Exactly five files changed, one README per plugin.
2. No source component (command, script, skill, agent, template) was modified.
3. For each plugin: the set of components named in the README equals the set on disk.
