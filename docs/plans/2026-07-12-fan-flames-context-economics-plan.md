# Fan-Flames Context Economics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use workspace-jj:fan-flames (per CLAUDE.md override of superpowers:subagent-driven-development) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port two Superpowers 6.x subagent-driven-development improvements into fan-flames: (1) file handoffs — task briefs, implementer report files, and file-path reviewer inputs replace pasted text in every dispatch prompt; (2) a durable append-only progress ledger that survives context compaction and makes runs resumable.

**Architecture:** A shared artifacts directory at `/tmp/jj-workspaces/<repo-basename>/artifacts/` (sibling of the workspace dirs fan-flames already creates) holds task briefs, report files, a prior-waves summary, and the ledger. Two new bash scripts in `plugins/workspace-jj/scripts/` resolve the artifacts dir and extract task briefs from plan files. The fan-flames skill and wave-reviewer template are edited to pass file paths instead of pasted text and to write ledger lines at every phase transition. The `/fan-flames` command (currently stale at v2) becomes a thin delegation to the skill so the two can never drift again.

**Tech Stack:** Bash (scripts + tests), Markdown (skill/command/template edits), jj (all VCS operations — no raw git anywhere, including inside the new scripts).

**Background:** fan-flames was forked from Superpowers 5-era subagent-driven-development. Superpowers 6.x added file handoffs (`scripts/task-brief`, `scripts/review-package`, report files, <15-line subagent returns) and a durable progress ledger after observing real failures: a 42k-char dispatch prompt that was 99% pasted history, and post-compaction controllers re-dispatching entire completed task sequences. This plan ports those two mechanisms in jj-native form. Reviewer hardening, model selection, and fix-dispatch contracts (items #3–#5 from the comparison) are explicitly out of scope.

## Global Constraints

- **No raw git commands anywhere** — skill text, scripts, and tests use jj equivalents only (`jj root`, not `git rev-parse --show-toplevel`).
- **Artifacts directory path is exactly** `/tmp/jj-workspaces/$(basename $(jj root))/artifacts` — single source of truth is the `fan-flames-artifacts` script; no other file may hardcode-derive it differently.
- **Artifact file names are exactly:** `task-<N>-brief.md`, `task-<N>-report.md`, `prior-waves.md`, `progress.md`.
- **Ledger is append-only** with the exact line grammar defined in Task 3; lines are lowercase, one event per line.
- **Subagent short-return contract:** implementers return under 15 lines; full detail goes in the report file.
- **Scripts are executable** (`chmod +x`) and use `set -euo pipefail`.
- **Skill references scripts relative to the skill file's directory:** `../scripts/fan-flames-artifacts` and `../scripts/fan-flames-task-brief` (skills live at `plugins/workspace-jj/skills/*.md`, scripts at `plugins/workspace-jj/scripts/`).
- **Commit convention:** conventional commits scoped to the plugin, e.g. `feat(fan-flames): …`, committed with `jj describe -m "…"` then `jj new`.

---

### Task 1: Artifacts-dir and task-brief scripts

**Files:**
- Create: `plugins/workspace-jj/scripts/fan-flames-artifacts`
- Create: `plugins/workspace-jj/scripts/fan-flames-task-brief`
- Test: `plugins/workspace-jj/tests/test-fan-flames-scripts.sh`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `fan-flames-artifacts` — no args, prints the absolute artifacts dir path (creating it if needed), exit 0; exits nonzero outside a jj repo. `fan-flames-task-brief PLAN_FILE TASK_NUMBER [OUTFILE]` — extracts the full text of `Task N` (a markdown heading matching `^#+ Task N`) from PLAN_FILE into OUTFILE (default `<artifacts-dir>/task-N-brief.md`), prints `wrote <path>: <n> lines`, exit 2 on usage/missing plan, exit 3 if the task heading is not found. Tasks 2–5 reference these scripts by these exact names and contracts.

- [ ] **Step 1: Write the failing test script**

Create `plugins/workspace-jj/tests/test-fan-flames-scripts.sh`:

````bash
#!/usr/bin/env bash
# Tests for fan-flames-artifacts and fan-flames-task-brief.
# Runs in a throwaway jj repo under mktemp; requires jj on PATH.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
PASS=0
FAIL=0

check() { # check DESCRIPTION COMMAND...
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: $desc"; PASS=$((PASS+1))
  else
    echo "FAIL: $desc"; FAIL=$((FAIL+1))
  fi
}

check_fails() { # check_fails DESCRIPTION EXPECTED_EXIT COMMAND...
  local desc=$1 expected=$2; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    echo "PASS: $desc"; PASS=$((PASS+1))
  else
    echo "FAIL: $desc (exit $actual, expected $expected)"; FAIL=$((FAIL+1))
  fi
}

tmp=$(mktemp -d)
repo="$tmp/fan-flames-test-$$"
trap 'rm -rf "$tmp" "/tmp/jj-workspaces/$(basename "$repo")"' EXIT

# Fixture: a jj repo (uniquely named so its /tmp artifacts dir cannot collide
# with a real repo's) and a plan file with three tasks and a decoy heading
# inside a code fence.
mkdir -p "$repo"
(cd "$repo" && jj git init >/dev/null 2>&1)
cat > "$repo/plan.md" <<'EOF'
# Example Plan

## Overview

Intro text that belongs to no task.

### Task 1: First thing

**Files:** `a.ts`

- [ ] Step 1: do the first thing

### Task 2: Second thing

**Files:** `b.ts`

Body of task two, line one.

```markdown
### Task 9: decoy heading inside a code fence
this line must not terminate or start a task
```

Body of task two, line two (after the fence).

### Task 3: Third thing

**Files:** `c.ts`
EOF

cd "$repo"

# --- fan-flames-artifacts ---
dir=$("$SCRIPTS/fan-flames-artifacts")
check "artifacts prints a path under /tmp/jj-workspaces" \
  test "${dir#/tmp/jj-workspaces/}" != "$dir"
check "artifacts dir exists" test -d "$dir"
check "artifacts path ends in /artifacts" \
  test "$(basename "$dir")" = "artifacts"
check "artifacts is idempotent" \
  test "$("$SCRIPTS/fan-flames-artifacts")" = "$dir"

# --- fan-flames-task-brief ---
out=$("$SCRIPTS/fan-flames-task-brief" plan.md 2)
brief="$dir/task-2-brief.md"
check "brief reports the file it wrote" \
  test "${out#wrote $brief:}" != "$out"
check "brief file exists" test -f "$brief"
check "brief contains its own heading" grep -q '^### Task 2: Second thing' "$brief"
check "brief contains post-fence body" grep -q 'line two (after the fence)' "$brief"
check "brief keeps the fenced decoy verbatim" grep -q 'Task 9: decoy' "$brief"
check_fails "brief excludes Task 1" 1 grep -q 'First thing' "$brief"
check_fails "brief excludes Task 3" 1 grep -q 'Third thing' "$brief"

"$SCRIPTS/fan-flames-task-brief" plan.md 3 "$tmp/custom-out.md" >/dev/null
check "explicit OUTFILE honored" grep -q 'Third thing' "$tmp/custom-out.md"

check_fails "missing task exits 3" 3 "$SCRIPTS/fan-flames-task-brief" plan.md 42
check_fails "missing plan exits 2" 2 "$SCRIPTS/fan-flames-task-brief" nope.md 1
check_fails "bad usage exits 2" 2 "$SCRIPTS/fan-flames-task-brief" plan.md

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
````

Make it executable:

```bash
chmod +x plugins/workspace-jj/tests/test-fan-flames-scripts.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `plugins/workspace-jj/tests/test-fan-flames-scripts.sh`
Expected: FAIL — script errors because `plugins/workspace-jj/scripts/fan-flames-artifacts` does not exist yet.

- [ ] **Step 3: Write `fan-flames-artifacts`**

Create `plugins/workspace-jj/scripts/fan-flames-artifacts`:

```bash
#!/usr/bin/env bash
# Resolve and ensure the shared artifacts directory for a fan-flames run:
# task briefs, implementer reports, the prior-waves summary, and the
# progress ledger. Prints the directory's absolute path.
#
# The directory lives in /tmp next to the run's jj workspaces — outside
# every working copy, so no workspace snapshot ever picks the artifacts up
# and nothing here can leak into a squashed change.
#
# Single source of truth for the location, so fan-flames-task-brief and the
# skill text cannot drift to different directories.
#
# Usage: fan-flames-artifacts
set -euo pipefail

root=$(jj root)
dir="/tmp/jj-workspaces/$(basename "$root")/artifacts"
mkdir -p "$dir"
printf '%s\n' "$dir"
```

```bash
chmod +x plugins/workspace-jj/scripts/fan-flames-artifacts
```

- [ ] **Step 4: Write `fan-flames-task-brief`**

Create `plugins/workspace-jj/scripts/fan-flames-task-brief`:

```bash
#!/usr/bin/env bash
# Extract one task's full text from an implementation plan into a file the
# implementer reads in one call, so the task text never has to be pasted
# through the orchestrator's context.
#
# A task starts at a markdown heading matching "Task N" (any heading level)
# and ends at the next task heading. Headings inside code fences are ignored.
#
# Usage: fan-flames-task-brief PLAN_FILE TASK_NUMBER [OUTFILE]
# Default OUTFILE: <artifacts-dir>/task-<N>-brief.md
set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: fan-flames-task-brief PLAN_FILE TASK_NUMBER [OUTFILE]" >&2
  exit 2
fi

plan=$1
n=$2
[ -f "$plan" ] || { echo "no such plan file: $plan" >&2; exit 2; }

if [ $# -eq 3 ]; then
  out=$3
else
  dir=$("$(cd "$(dirname "$0")" && pwd)/fan-flames-artifacts")
  out="$dir/task-${n}-brief.md"
fi

awk -v n="$n" '
  /^```/ { infence = !infence }
  !infence && /^#+[ \t]+Task[ \t]+[0-9]+/ {
    intask = ($0 ~ ("^#+[ \t]+Task[ \t]+" n "([^0-9]|$)"))
  }
  intask { print }
' "$plan" > "$out"

if [ ! -s "$out" ]; then
  echo "task ${n} not found in ${plan} (no heading matching 'Task ${n}')" >&2
  exit 3
fi

echo "wrote ${out}: $(wc -l < "$out" | tr -d ' ') lines"
```

```bash
chmod +x plugins/workspace-jj/scripts/fan-flames-task-brief
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `plugins/workspace-jj/tests/test-fan-flames-scripts.sh`
Expected: all checks PASS, final line `… 0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(fan-flames): add artifacts-dir and task-brief scripts

File-handoff plumbing ported from superpowers 6.x subagent-driven-development:
fan-flames-artifacts resolves the shared /tmp artifacts dir, fan-flames-task-brief
extracts one task's text from a plan so it is never pasted through the
orchestrator's context."
jj new
```

---

### Task 2: File handoffs in the fan-flames skill (briefs, reports, prior-waves)

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md`

**Interfaces:**
- Consumes: script names and contracts from Task 1 (`../scripts/fan-flames-artifacts`, `../scripts/fan-flames-task-brief PLAN_FILE N`).
- Produces: artifact file conventions used by Tasks 3–4: briefs at `<artifacts>/task-N-brief.md`, implementer reports at `<artifacts>/task-N-report.md` (fix subagents append to the same file), prior-wave summary at `<artifacts>/prior-waves.md`. The implementer short-return contract (Status / Change ID / Workspace / Files / one-line tests / concerns / report path, under 15 lines).

- [ ] **Step 1: Add the Artifacts Directory section**

In `plugins/workspace-jj/skills/fan-flames.md`, insert a new section immediately after the `## Input` section (after the line `If given a plan document, read it and extract all tasks with their full text.`, currently line 81):

````markdown
## Artifacts Directory

All run artifacts live in one shared directory outside every working copy, so
no workspace snapshot ever picks them up and nothing bulky is pasted through
the orchestrator's context:

```bash
../scripts/fan-flames-artifacts   # prints /tmp/jj-workspaces/<repo>/artifacts, creating it
```

(Script paths are relative to this skill file's directory.)

| File | Written by | Read by |
|------|-----------|---------|
| `task-N-brief.md` | PLAN (task-brief script, or Write for ad-hoc tasks) | implementers, fix subagents, reviewers |
| `task-N-report.md` | implementer; fix subagents append | reviewers; orchestrator only on demand |
| `prior-waves.md` | orchestrator, appended after each wave's FAN IN | Wave 2+ implementers |
| `progress.md` | orchestrator, at every phase transition | orchestrator (resume after compaction) |

**Rule: hand artifacts to subagents as file paths, never as pasted text.**
Everything pasted into a dispatch prompt — and everything a subagent prints
back — stays resident in the orchestrator's context for the rest of the run
and is re-read on every later turn. A real superpowers session hit a 42k-char
dispatch prompt that was 99% pasted history; file handoffs are how fan-flames
avoids that failure mode.
````

- [ ] **Step 2: Add brief generation to the PLAN phase**

In the same file, at the end of Phase 1 (after the `5. **Recommend** 3-5 concurrent workspaces per wave…` line, currently line 148), add:

```markdown
### Prepare Artifacts

Once waves are confirmed:

1. Resolve the artifacts directory: `../scripts/fan-flames-artifacts`
2. Write one brief per task:
   - **Plan document input:** `../scripts/fan-flames-task-brief <plan-file> <N>`
     for each task — the script extracts the task's full text without it
     passing through your context again
   - **Ad-hoc input:** Write `<artifacts>/task-N-brief.md` yourself containing
     the full task description
3. Initialize the progress ledger (see Durable Progress and Resume)
```

- [ ] **Step 3: Rewrite the FAN OUT dispatch prompt to use file handoffs**

In Phase 2 Step 2 ("Dispatch agents"), replace the current prompt template (the fenced block currently at lines 173–231, beginning `Agent tool:` and ending with the `- Any concerns` bullet) with:

````markdown
```
Agent tool:
  description: "Task N: <short description>"
  prompt: |
    ## Working Directory
    CRITICAL: Your first action MUST be:
      cd <workspace-path>
    ALL work happens in that directory. Do not operate in any other directory.
    Verify you are in the right workspace:
      jj workspace list
    Confirm you see workspace-<task-name> marked as the active workspace.

    ## Your Task

    Read your task brief first — it is your requirements, with the exact
    values to use verbatim:
      <artifacts>/task-N-brief.md

    <one line: where this task fits in the overall plan>

    <if wave > 1: "Changes from prior waves are already in your working copy.
    Read <artifacts>/prior-waves.md before starting — build on that work,
    don't duplicate or conflict with it.">

    <only if needed: interfaces or decisions the brief cannot know, e.g.
    exact signatures produced by an earlier wave>

    CRITICAL: You MUST NOT use ANY raw git commands — not even for context
    discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.).
    The only exceptions are `jj git` subcommands and `gh` CLI.

    ## Self-Review Before Reporting

    Before reporting back, review your work with fresh eyes:

    - Completeness: did I implement everything in the spec?
    - Quality: are names clear, code maintainable?
    - Discipline: did I avoid overbuilding (YAGNI)?
    - Testing: do tests verify behavior, not just mock it?
    - Formatting: run the project's formatter/linter (e.g., cargo fmt, prettier, ruff) and fix any issues

    If you find issues, fix them now before reporting.

    ## When You're in Over Your Head

    It is always OK to stop and say "this is too hard for me."
    Bad work is worse than no work.

    STOP and escalate when:
    - The task requires architectural decisions with multiple valid approaches
    - You need to understand code beyond what was provided
    - You feel uncertain about your approach
    - The task involves restructuring the plan didn't anticipate

    ## Reporting

    Write your full report to <artifacts>/task-N-report.md:
    - What you implemented (or attempted, if blocked)
    - What you tested and the test results
    - Files changed, with one line on what changed in each
    - Self-review findings (if any)
    - Any issues or concerns

    Before reporting back, capture your change ID and workspace name:
    jj log -r @ --no-graph -T 'change_id'
    basename "$PWD"

    Then report back ONLY the following, under 15 lines — the detail lives
    in the report file:
    - Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
    - Change ID: <the change_id from above>
    - Workspace directory: <the basename from above>
    - Files changed: paths only
    - One-line test summary (e.g. "14/14 passing")
    - Concerns, if any
    - Report file: <artifacts>/task-N-report.md

    If BLOCKED or NEEDS_CONTEXT, put the specifics in your final message
    itself — the orchestrator acts on it directly.
```
````

(`<artifacts>` is the absolute path printed by `../scripts/fan-flames-artifacts` — substitute the real path when composing each prompt.)

- [ ] **Step 4: Update the dispatch rules**

In the **Dispatch rules** list directly below the template (currently lines 233–239), replace the bullet:

```markdown
- Provide each subagent with the full task text, not a summary
```

with:

```markdown
- Point each subagent at its brief file — never paste task text, plan
  excerpts, or prior-wave summaries into the prompt
```

- [ ] **Step 5: Replace the pasted prior-wave context with prior-waves.md**

Replace the entire **Prior wave context (Wave 2+ only):** block (currently lines 241–256, from `**Prior wave context (Wave 2+ only):**` through `Don't paste full diffs.`) with:

```markdown
**Prior wave context (Wave 2+ only):**

After each wave's FAN IN, append a concise summary of what that wave merged
to `<artifacts>/prior-waves.md` (see Phase 5). Wave 2+ dispatch prompts
reference that file by path — the summary is written once per wave and read
by every later agent, instead of being pasted into each prompt.

Keep entries concise — files, functions/types added or changed, and key APIs.
Never full diffs.
```

- [ ] **Step 6: Point reviewers and the fix loop at the artifact files**

In Phase 4 Step 2, replace the template fill-in list (currently lines 357–361):

```markdown
- `[WAVE_NUMBER]` — the current wave number
- `[FULL TEXT of all task specs in this wave]` — paste complete task text for every task
- `[FILES_TO_REVIEW]` — the files assigned to this reviewer
- `[CHANGE_IDS]` — the jj change IDs from the implementers
```

with:

```markdown
- `[WAVE_NUMBER]` — the current wave number
- `[BRIEF_FILES]` — paths to the brief files of every task in the wave
  (`<artifacts>/task-N-brief.md` — paths, not pasted text)
- `[REPORT_FILES]` — paths to the implementer report files
  (`<artifacts>/task-N-report.md`)
- `[FILES_TO_REVIEW]` — the files assigned to this reviewer
- `[CHANGE_IDS]` — the jj change IDs from the implementers
```

In the **Fix Loop** list (currently lines 378–384), replace item 2:

```markdown
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED / NEEDS_CONTEXT)
```

with:

```markdown
2. Fix subagent uses the same implementer protocol (DONE / BLOCKED /
   NEEDS_CONTEXT) and appends its fix report — what it changed and the
   test results — to the task's existing `<artifacts>/task-N-report.md`
```

- [ ] **Step 7: Verify the edits**

```bash
grep -n "FULL TEXT" plugins/workspace-jj/skills/fan-flames.md
grep -n "full task text" plugins/workspace-jj/skills/fan-flames.md
grep -c "task-N-brief.md" plugins/workspace-jj/skills/fan-flames.md
```

Expected: the first two greps return nothing; the third returns at least 3.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(fan-flames): file handoffs — briefs, report files, prior-waves summary

Dispatch prompts now point at task brief files instead of pasted task text;
implementers write full reports to files and return <15 lines; Wave 2+ context
moves to a shared prior-waves.md written once per wave. Ported from
superpowers 6.x subagent-driven-development."
jj new
```

---

### Task 3: Durable progress ledger

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames.md`

**Interfaces:**
- Consumes: artifacts dir and `progress.md` naming from Tasks 1–2.
- Produces: the ledger line grammar below, referenced by the Report phase and by any future resume tooling.

Ledger line grammar (append-only, lowercase, one event per line):

```
# fan-flames ledger — plan: <path or "ad-hoc"> — parent: <change-id of @->
wave-plan: wave 1: tasks 1,2,4 | wave 2: tasks 3,5
task <N>: dispatched workspace=workspace-<task-name>
task <N>: done change=<change-id> files=<comma-separated-paths>
task <N>: done-with-concerns change=<change-id> files=<paths>
task <N>: blocked reason=<short reason>
task <N>: needs-context
task <N>: workspace-leak
task <N>: review-passed
task <N>: review-failed findings=<n-critical>c,<n-important>i
task <N>: squashed
wave <W>: fanned-in
run: complete
```

The latest line for a task wins. Ledger appends happen in the same message as the phase's other bookkeeping — never as a separate turn.

- [ ] **Step 1: Add the Durable Progress and Resume section**

In `plugins/workspace-jj/skills/fan-flames.md`, insert a new section immediately after the `## Artifacts Directory` section added in Task 2:

````markdown
## Durable Progress and Resume

Conversation memory does not survive compaction. An orchestrator that loses
its place re-dispatches entire completed waves — the most expensive failure
mode superpowers observed in real sessions. The ledger at
`<artifacts>/progress.md` is the recovery map: the change IDs it names exist
in jj's DAG even when your context no longer remembers creating them.

Append-only line format (latest line for a task wins):

```
# fan-flames ledger — plan: docs/plans/foo-plan.md — parent: xyzabc12
wave-plan: wave 1: tasks 1,2,4 | wave 2: tasks 3,5
task 1: dispatched workspace=workspace-task-1
task 1: done change=abc12345 files=src/a.ts,src/b.ts
task 1: review-passed
task 1: squashed
wave 1: fanned-in
run: complete
```

Event lines: `dispatched workspace=…`, `done change=… files=…`,
`done-with-concerns change=… files=…`, `blocked reason=…`, `needs-context`,
`workspace-leak`, `review-passed`, `review-failed findings=<n>c,<n>i`,
`squashed`, `wave <W>: fanned-in`, `run: complete`.

Write ledger lines in the same message as the phase's other bookkeeping —
never as a separate turn.

### Resume Check (at skill start, before PLAN)

Check for a ledger from an interrupted run:

```bash
cat "$(../scripts/fan-flames-artifacts)/progress.md" 2>/dev/null
```

If it exists and does not end with `run: complete`, a previous run was
interrupted. Report what the ledger shows and ask the user: resume or start
fresh. On resume:

- Tasks marked `squashed` are DONE — never re-dispatch them
- Tasks marked `done`/`review-passed` but not `squashed` — their change IDs
  are in the ledger; resume at REVIEW or FAN IN using those IDs
- Tasks marked `dispatched` with no later line — the agent died mid-flight;
  check `jj log -r 'description("Task N:")'` and the workspace before
  re-dispatching
- Trust the ledger and `jj log` over your own recollection

On start fresh: overwrite the ledger with a new header when PLAN initializes it.
````

- [ ] **Step 2: Add the resume check to Prerequisites**

In the `## Prerequisites` numbered list (currently ending at item 3, `**Clean working copy**…`), add:

```markdown
4. **Resume check** — look for a ledger from an interrupted run (see Durable
   Progress and Resume). If one exists, resolve resume-vs-fresh with the user
   before planning.
```

- [ ] **Step 3: Wire ledger writes into PLAN**

In the `### Prepare Artifacts` subsection added in Task 2, replace step 3 (`3. Initialize the progress ledger (see Durable Progress and Resume)`) with:

````markdown
3. Initialize the ledger — write the header and wave plan to
   `<artifacts>/progress.md`:

   ```
   # fan-flames ledger — plan: <plan path or "ad-hoc"> — parent: <change-id of @->
   wave-plan: wave 1: tasks … | wave 2: tasks …
   ```
````

- [ ] **Step 4: Wire ledger writes into FAN OUT and COLLECT**

In Phase 2, in the **Progress tracking** block (currently line 258, `- After dispatch, report how many subagents are running:`), add a second bullet after it:

```markdown
- Append one ledger line per dispatched task:
  `task N: dispatched workspace=workspace-<task-name>`
```

In Phase 3 (COLLECT), after the paragraph beginning `Track which tasks succeeded and which failed.` (currently line 281), add:

```markdown
As each result is classified, append its ledger line: `task N: done
change=<id> files=<paths>` (or `done-with-concerns …`, `blocked reason=…`,
`needs-context`). If the integrity check flags a leak, append
`task N: workspace-leak`.
```

- [ ] **Step 5: Wire ledger writes into REVIEW and FAN IN**

In Phase 4, in **Handling Review Results** after the findings/severity table (currently line 372), add:

```markdown
Append a ledger line per task as verdicts land: `task N: review-passed` or
`task N: review-failed findings=<n>c,<n>i` (append `review-passed` after a
successful fix loop).
```

In Phase 5, Step 2b, after the squash command block (`JJ_EDITOR=true jj squash --from <change-id> --into @`, currently line 515), add to the numbered list:

```markdown
3. **Append the ledger line:** `task N: squashed`
```

At the end of Phase 5 (after the `**For each failed task:**` block, currently line 536), add:

````markdown
### After the Wave's FAN IN

1. Append `wave W: fanned-in` to the ledger
2. Append the wave's summary to `<artifacts>/prior-waves.md` (for Wave 2+
   dispatch prompts):

   ```markdown
   ## Wave W (merged into @)
   - Task N: <file>: added <functions/types>; <file>: updated <what changed>
   ```

   Build it from the implementers' short returns; run
   `jj diff -r <change-id> --stat` if you need to refresh which files a task
   touched. Never paste diffs.
````

(For Pattern A waves, where no squash is needed, the same two appends apply once content is verified.)

- [ ] **Step 6: Close the ledger in the Report phase**

In Phase 6, after the first paragraph (`After all waves complete, report plan coverage. …`, currently line 541), add:

```markdown
Append `run: complete` to the ledger — this is what the resume check keys on.
```

- [ ] **Step 7: Verify the edits**

```bash
grep -c "progress.md" plugins/workspace-jj/skills/fan-flames.md
grep -n "run: complete" plugins/workspace-jj/skills/fan-flames.md
grep -n "task N: squashed" plugins/workspace-jj/skills/fan-flames.md
```

Expected: `progress.md` appears at least 3 times; `run: complete` appears in both the Durable Progress section and Phase 6; `task N: squashed` appears in Phase 5.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(fan-flames): durable progress ledger with resume protocol

Append-only ledger at <artifacts>/progress.md written at every phase
transition; skill-start resume check recovers interrupted runs from ledger +
jj log instead of conversation memory. Ported from superpowers 6.x
subagent-driven-development's progress ledger."
jj new
```

---

### Task 4: Wave-reviewer template takes file paths

**Files:**
- Modify: `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md`

**Interfaces:**
- Consumes: `[BRIEF_FILES]` / `[REPORT_FILES]` placeholder names and artifact file conventions from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Replace the pasted-spec section of the template**

In `plugins/workspace-jj/skills/fan-flames-wave-reviewer.md`, replace the template's requirements section (currently lines 21–23):

```markdown
    ## What Was Requested (Wave [WAVE_NUMBER])

    [FULL TEXT of all task specs in this wave]
```

with:

```markdown
    ## What Was Requested (Wave [WAVE_NUMBER])

    Read the task briefs first — they are the requirements and your ground
    truth for what was asked:

    [BRIEF_FILES]

    ## What the Implementers Claim They Built

    Read the implementer reports:

    [REPORT_FILES]

    Treat the reports as unverified claims — verify them against the code,
    not the other way around.
```

- [ ] **Step 2: Update the placeholders list**

Replace the `## Placeholders` list (currently lines 77–82):

```markdown
- `[WAVE_NUMBER]` — the current wave number
- `[FULL TEXT of all task specs in this wave]` — paste the complete task text for every task in the wave, not a summary
- `[FILES_TO_REVIEW]` — list of file paths assigned to this reviewer
- `[CHANGE_IDS]` — the jj change IDs from the implementers (may be multiple if reviewer covers multiple tasks)
```

with:

```markdown
- `[WAVE_NUMBER]` — the current wave number
- `[BRIEF_FILES]` — paths to the wave's task brief files
  (`<artifacts>/task-N-brief.md`), one per line — paths, never pasted text
- `[REPORT_FILES]` — paths to the implementer report files
  (`<artifacts>/task-N-report.md`), one per line
- `[FILES_TO_REVIEW]` — list of file paths assigned to this reviewer
- `[CHANGE_IDS]` — the jj change IDs from the implementers (may be multiple if reviewer covers multiple tasks)
```

- [ ] **Step 3: Update the template's purpose note**

Replace the **Purpose** line (currently line 5):

```markdown
**Purpose:** Verify spec compliance AND code quality in a single pass. The reviewer has the full task specs as ground truth, eliminating hallucinations about intent.
```

with:

```markdown
**Purpose:** Verify spec compliance AND code quality in a single pass. The reviewer reads the task brief files as ground truth, eliminating hallucinations about intent — and the briefs travel as file paths, never as pasted text in the orchestrator's context.
```

- [ ] **Step 4: Verify the edits**

```bash
grep -n "FULL TEXT" plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
grep -c "BRIEF_FILES" plugins/workspace-jj/skills/fan-flames-wave-reviewer.md
```

Expected: first grep returns nothing; second returns at least 2.

- [ ] **Step 5: Commit**

```bash
jj describe -m "feat(fan-flames): wave reviewers read brief and report files by path

Reviewer template takes [BRIEF_FILES]/[REPORT_FILES] paths instead of pasted
task specs, and treats implementer reports as unverified claims."
jj new
```

---

### Task 5: Command file delegates to the skill

The command at `plugins/workspace-jj/commands/fan-flames.md` is stale at v2: it still instructs `isolation: "worktree"`, checks for WorktreeCreate hooks, references `fan-flames-spec-reviewer.md` (a file that no longer exists), and has a VERIFY phase the v3 skill removed. Rather than syncing its copy of the workflow a third time, make it a thin delegation to the skill so drift is structurally impossible. Note one deliberate flag change: `--skip-spec-review` (v2-only) is dropped; the skill's `--skip-review` covers skipping the REVIEW phase.

**Files:**
- Modify: `plugins/workspace-jj/commands/fan-flames.md` (full rewrite)

**Interfaces:**
- Consumes: the skill's flags table (`--merge-order`, `--skip-review`) from `plugins/workspace-jj/skills/fan-flames.md`.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Rewrite the command file**

Replace the entire contents of `plugins/workspace-jj/commands/fan-flames.md` with:

```markdown
---
description: "Execute a plan using wave-based parallel orchestration with spec review gates"
argument-hint: "[plan-file] [--skip-review] [--merge-order auto|task-1,task-2,...]"
allowed-tools: Agent, Bash, Read, Write, Edit, Glob, Grep, Skill
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands and `gh` CLI.**

# Fan-Flames

Invoke the `workspace-jj:fan-flames` skill and follow it exactly — the skill
is the single source of truth for the fan-flames workflow (phases, prompts,
artifacts, ledger, and flags).

Arguments to pass through: $ARGUMENTS

- **plan-file** — path to a plan document with numbered tasks. If no plan
  file is given, ask the user for a plan document or an ad-hoc task list.
- **--skip-review** — skip the REVIEW phase (see the skill's Flags table)
- **--merge-order** — `auto` (default) or an explicit task order
```

- [ ] **Step 2: Verify no orphaned references remain**

```bash
grep -rn "fan-flames-spec-reviewer" plugins/ docs/ --include="*.md" | grep -v docs/plans | grep -v docs/specs
grep -n "skip-spec-review" plugins/workspace-jj/commands/fan-flames.md
```

Expected: both return nothing (historical plans/specs may still mention the old template; live plugin files must not).

- [ ] **Step 3: Commit**

```bash
jj describe -m "refactor(fan-flames): command delegates to the skill

The /fan-flames command was stale at v2 (worktree isolation, WorktreeCreate
hook checks, missing fan-flames-spec-reviewer.md, removed VERIFY phase).
It now invokes the workspace-jj:fan-flames skill as the single source of
truth. Drops the v2-only --skip-spec-review flag; --skip-review covers it."
jj new
```

---

## Out of Scope (deliberately)

- Reviewer hardening (don't-trust-the-report calibration beyond the one line added in Task 4, ⚠️ cannot-verify channel, anti-pre-judging rules) — item #4 from the SDD comparison
- Model selection guidance per dispatch — item #3
- Fix-dispatch evidence contract and finding batching — item #5
- Pre-flight plan review — item #6
- `plugins/workspace-jj/README.md` line 46 still mentions `isolation: "worktree"` for subagents — a v3-cleanup leftover, separate change

## Verification (whole branch)

1. `plugins/workspace-jj/tests/test-fan-flames-scripts.sh` — all pass
2. `grep -rn "FULL TEXT\|full task text" plugins/workspace-jj/` — no hits
3. Read `plugins/workspace-jj/skills/fan-flames.md` top to bottom once: every phase that produces state appends a ledger line; every dispatch prompt references artifacts by path; no instruction says "paste"
