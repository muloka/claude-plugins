# Kaisen Rename + Collision + Path Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Do NOT use workspace-jj:fan-flames for this plan.** Two independent reasons: (1) the skill is
> currently unreachable — a command of the same name shadows it, which is Task 4's subject; and
> (2) Tasks 2, 3, and 4 all modify the same file (`skills/fan-flames/SKILL.md`), so the overlap
> graph collapses to one task per wave and fan-flames' own Parallelism Threshold rule directs you
> to sequential execution. Inline execution is correct.

**Goal:** Fix four mutually-masking defects in `workspace-jj` and CI, and rename the `fan-flames`
skill to `kaisen`.

**Architecture:** Four defects, fixed in dependency order. D (CI crashes on deletions) goes first
because it blocks the PR. C (broken script paths) is fixed under a new lint that proves the bug
before fixing it. B (command shadows skill) and the rename land together, since deleting the
wrapper is what frees the name. Cross-plugin references and version bumps ship last, because they
are what makes any of it reach a user.

**Tech Stack:** Bash, jj (Jujutsu), GitHub Actions, bun.

## Global Constraints

- **jj, never git.** This repo uses Jujutsu. Use `jj` for all VCS operations. The only exceptions
  are `jj git` subcommands and the `gh` CLI. Raw `git` is blocked by a PreToolUse hook.
- **`docs/plans/` and `docs/specs/` are frozen.** They are historical records of past state. Do
  not update `fan-flames` references in them. Only `plugins/`, `.github/`, and root `CLAUDE.md`
  change.
- **Phase names stay literal.** `FAN OUT 🪭` and `FAN IN 🔥` are read by agents. Do not rename them.
- **Verify by content, never by success messages.** Three times on 2026-07-15 a green signal was
  wrong: CI passed by never running, `plugin update` said "already at the latest version" while
  serving stale files, and #81 merged green with six broken paths.
- **Version bumps are load-bearing** (#84): `workspace-jj` → `0.1.2`, `project-setup-jj` → `0.1.1`.
  Without them nothing ships.
- **The template hash is load-bearing:** editing `CLAUDE.md.template`'s body without changing its
  `hash:` marker means the fix reaches nobody.
- Spec: `docs/specs/2026-07-15-kaisen-rename-and-collision-design.md`

---

### Task 1: Fix CI's handling of deleted files (defect D)

CI selects files with `gh pr diff --name-only` and pipes them to a validator whose
`detectFileType` matches on the **path string only** — it never checks existence. A deleted path
is classified, queued, and handed to `readFile`, which throws. This PR deletes two matching files,
so without this fix CI fails on a correct change and blames the file we meant to delete.

`gh pr diff` has **no `--diff-filter`** flag (verified: its only flags are `--color`, `--exclude`,
`--name-only`, `--patch`, `--web`). Filter by existence instead — the `pull_request` checkout
holds the PR's tree, so "exists on disk" is exactly "survives this PR".

**Files:**
- Modify: `.github/workflows/validate-frontmatter.yml:24-31`

**Interfaces:**
- Consumes: nothing
- Produces: nothing consumed by later tasks. Independent; ordered first because it unblocks the PR.

- [ ] **Step 1: Reproduce the failure**

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
bun .github/scripts/validate-frontmatter.ts plugins/workspace-jj/skills/gone/SKILL.md; echo "exit: $?"
```

Expected: `Fatal error: ENOENT: no such file or directory, open '.../skills/gone/SKILL.md'` and
`exit: 2`. This is the bug — a path that does not exist crashes the validator.

- [ ] **Step 2: Apply the existence filter**

In `.github/workflows/validate-frontmatter.yml`, replace:

```yaml
          FILES=$(gh pr diff ${{ github.event.pull_request.number }} --name-only | grep -E '(agents/.*\.md|skills/.*/SKILL\.md|commands/.*\.md)$' || true)
```

with:

```yaml
          # Filter to files that still EXIST. detectFileType matches on the path
          # string alone, so a deleted path is classified, queued, and readFile'd —
          # exiting 2 with ENOENT and failing CI on a correct change. The
          # pull_request checkout holds the PR's tree, so "exists on disk" is the
          # same question as "survives this PR". `gh pr diff` has no --diff-filter.
          FILES=$(gh pr diff ${{ github.event.pull_request.number }} --name-only \
            | grep -E '(agents/.*\.md|skills/.*/SKILL\.md|commands/.*\.md)$' \
            | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done || true)
```

- [ ] **Step 3: Verify the filter drops absent paths and keeps present ones**

```bash
printf '%s\n' 'plugins/workspace-jj/skills/gone/SKILL.md' 'plugins/peer-review-jj/skills/requesting-change-review/SKILL.md' \
  | grep -E '(agents/.*\.md|skills/.*/SKILL\.md|commands/.*\.md)$' \
  | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done
```

Expected: exactly one line, `plugins/peer-review-jj/skills/requesting-change-review/SKILL.md`. The
absent path is gone.

- [ ] **Step 4: Verify the filtered list validates cleanly**

```bash
FILES=$(printf '%s\n' 'plugins/workspace-jj/skills/gone/SKILL.md' 'plugins/peer-review-jj/skills/requesting-change-review/SKILL.md' \
  | grep -E '(agents/.*\.md|skills/.*/SKILL\.md|commands/.*\.md)$' \
  | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done)
echo "$FILES" | xargs bun .github/scripts/validate-frontmatter.ts; echo "exit: $?"
```

Expected: `Validated 1 files: 0 errors, 0 warnings` and `exit: 0`. Was exit 2 before the filter.

- [ ] **Step 5: Commit**

```bash
jj commit -m "fix(ci): don't hand deleted files to the frontmatter validator

detectFileType matches on the path string alone and never checks
existence, so a deleted agent/skill/command .md is classified, queued,
and readFile'd — exiting 2 with ENOENT and failing CI on a correct
change.

Pre-existing since the workflow was written; never hit because no PR
had yet deleted one of those files.

gh pr diff has no --diff-filter, so filter by existence instead: the
pull_request checkout holds the PR's tree, so \"exists on disk\" is the
same question as \"survives this PR\".

Fixing the validator to skip missing files was rejected — that would
let a typo'd path pass silently, which is the same green-by-checking-
nothing failure as #82 and #84. The validator stays strict; the
workflow, which knows the scope, gets fixed."
```

---

### Task 2: Repair the skill's script paths, guarded by a new lint (defect C)

#81 moved the skill from `skills/fan-flames.md` to `skills/fan-flames/SKILL.md` — one directory
deeper — silently invalidating every `../scripts/` reference in its body. Six shipped in 0.1.1.

The lint is written **first** and must **fail**, proving both that the bug is real and that the
lint can see it. A lint that passes on its first run has proved nothing.

**Files:**
- Create: `plugins/workspace-jj/tests/test-skill-paths.sh`
- Modify: `plugins/workspace-jj/skills/fan-flames/SKILL.md` (lines 93, 170, 201, 322, 324, 473)

**Interfaces:**
- Consumes: nothing
- Produces: `tests/test-skill-paths.sh` — Tasks 3 and 4 re-run it unchanged after they move files.

- [ ] **Step 1: Write the failing lint**

Create `plugins/workspace-jj/tests/test-skill-paths.sh`:

```bash
#!/usr/bin/env bash
# Verifies that every relative script reference in a skill body resolves.
#
# Why this exists: PR #81 moved skills from skills/<name>.md to
# skills/<name>/SKILL.md — one directory deeper. Every `../scripts/...`
# reference in the body silently became wrong, and six of them shipped in
# 0.1.1. Nothing caught it: the script tests exercise the scripts directly,
# not the skill's references to them; CI validates frontmatter, not paths; and
# the skill was unreachable anyway (a command of the same name shadowed it), so
# the paths were never executed. Prose is not run, so it is not checked.
#
# The skill's convention is "script paths are relative to this skill file's
# directory". That is sound — the Skill tool announces the base directory on
# load — but nothing verified the paths were true.
#
# Design note: this extracts the WHOLE reference (all leading ../ included) and
# resolves it. It does not try to pattern-match the *wrong* form. That matters:
# `../../scripts/` CONTAINS the substring `../scripts/`, so a detector for the
# bad form reports the correct form as a bug unless carefully anchored.
# Resolution sidesteps the trap entirely and also catches renamed or deleted
# scripts for free.
#
# Usage: test-skill-paths.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLUGINS="$ROOT/plugins"
PASS=0
FAIL=0
REFS=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# --- Rule 1: every relative script reference resolves ---
while IFS= read -r skill; do
  dir=$(dirname "$skill")
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    REFS=$((REFS+1))
    if [ -e "$dir/$ref" ]; then
      ok "$(basename "$dir")/$(basename "$skill"): $ref"
    else
      bad "$(basename "$dir")/$(basename "$skill"): $ref does not resolve (tried $dir/$ref)"
    fi
  done < <(grep -oE '(\.\./)+scripts/[A-Za-z0-9_.-]+' "$skill" | sort -u)
done < <(find "$PLUGINS" -path '*/skills/*/SKILL.md' | sort)

# --- Rule 2: finding zero references means the extractor is broken ---
#
# A lint that checks nothing passes silently, which is the failure this repo
# has hit repeatedly (#82: a glob matching zero files; #84: an unchanged
# version). At least one skill here references scripts. Zero matches means the
# regex rotted, not that the repo is clean.
if [ "$REFS" -eq 0 ]; then
  bad "no script references found in any skill — the extractor is broken, not the repo clean"
else
  ok "extractor found $REFS script reference(s)"
fi

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
```

- [ ] **Step 2: Make it executable and run it — it MUST fail**

```bash
chmod +x plugins/workspace-jj/tests/test-skill-paths.sh
bash plugins/workspace-jj/tests/test-skill-paths.sh; echo "exit: $?"
```

Expected: **FAIL**, `exit: 1`. Two `FAIL:` lines naming
`../scripts/fan-flames-artifacts` and `../scripts/fan-flames-task-brief` as not resolving (tried
`.../skills/fan-flames/../scripts/...`), plus a `PASS: extractor found 2 script reference(s)` line.
Both fan-flames refs deduplicate to 2 unique strings across the 6 sites.

If this run PASSES, stop — the lint is not seeing the bug, and fixing the paths under a blind lint
proves nothing.

- [ ] **Step 3: Fix the six paths**

```bash
sed -i '' 's|\.\./scripts/|../../scripts/|g' plugins/workspace-jj/skills/fan-flames/SKILL.md
```

**This sed is NOT idempotent.** Run it exactly once. On `../scripts/x` it yields `../../scripts/x`;
run again and the pattern matches at offset 3, yielding `../../../scripts/x`. Step 4 catches that.

- [ ] **Step 4: Run the lint — it MUST now pass**

```bash
bash plugins/workspace-jj/tests/test-skill-paths.sh; echo "exit: $?"
```

Expected: **PASS**, `exit: 0`, `3 passed, 0 failed` (two resolving refs + the extractor rule).

- [ ] **Step 5: Confirm the fix by content**

```bash
grep -n 'scripts/fan-flames' plugins/workspace-jj/skills/fan-flames/SKILL.md
```

Expected: exactly 6 lines (93, 170, 201, 322, 324, 473), every one reading `../../scripts/…`. No
line shows `../../../` and no line shows a bare `../scripts/`.

- [ ] **Step 6: Commit**

```bash
jj commit -m "fix(workspace-jj): repair skill script paths broken by the SKILL.md move

#81 moved the skill one directory deeper (skills/fan-flames.md ->
skills/fan-flames/SKILL.md), silently invalidating all six
../scripts/ references in its body. They shipped in 0.1.1.

Nothing caught it: the script tests exercise the scripts directly, not
the skill's references to them; CI validates frontmatter, not paths;
and the skill was unreachable anyway, so the paths never ran.

Adds tests/test-skill-paths.sh, which resolves every relative script
reference in every skill. It fails loudly on zero matches — a lint that
checks nothing is the bug it guards against."
```

---

### Task 3: Rename the helper scripts to `kaisen-*`

The two scripts carry the old name. Their six call sites are being edited in this PR anyway, so
renaming is nearly free. `fan-flames-task-brief` resolves its sibling **by name**, so a pure move
leaves it calling a script that no longer exists.

**Files:**
- Modify: `plugins/workspace-jj/scripts/fan-flames-artifacts` → `plugins/workspace-jj/scripts/kaisen-artifacts` (move)
- Modify: `plugins/workspace-jj/scripts/fan-flames-task-brief` → `plugins/workspace-jj/scripts/kaisen-task-brief` (move **and edit line 31**)
- Modify: `plugins/workspace-jj/tests/test-fan-flames-scripts.sh` → `plugins/workspace-jj/tests/test-kaisen-scripts.sh` (move and edit)
- Modify: `plugins/workspace-jj/skills/fan-flames/SKILL.md` (the 6 call sites)

**Interfaces:**
- Consumes: `tests/test-skill-paths.sh` from Task 2
- Produces: `scripts/kaisen-artifacts` (prints the artifacts dir, creating it),
  `scripts/kaisen-task-brief <plan-file> <N>` — Task 4 references both by these names.

- [ ] **Step 1: Move the scripts and the test**

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
mv plugins/workspace-jj/scripts/fan-flames-artifacts plugins/workspace-jj/scripts/kaisen-artifacts
mv plugins/workspace-jj/scripts/fan-flames-task-brief plugins/workspace-jj/scripts/kaisen-task-brief
mv plugins/workspace-jj/tests/test-fan-flames-scripts.sh plugins/workspace-jj/tests/test-kaisen-scripts.sh
```

- [ ] **Step 2: Run the script tests — they MUST fail**

```bash
bash plugins/workspace-jj/tests/test-kaisen-scripts.sh; echo "exit: $?"
```

Expected: **FAIL**, non-zero exit. The test still invokes `fan-flames-artifacts` /
`fan-flames-task-brief`, which no longer exist. This proves the test actually exercises the
scripts rather than passing vacuously.

- [ ] **Step 3: Fix the sibling resolution inside `kaisen-task-brief`**

In `plugins/workspace-jj/scripts/kaisen-task-brief` line 31, replace:

```bash
  dir=$("$(cd "$(dirname "$0")" && pwd)/fan-flames-artifacts")
```

with:

```bash
  dir=$("$(cd "$(dirname "$0")" && pwd)/kaisen-artifacts")
```

- [ ] **Step 4: Update every reference in the test and the skill**

```bash
sed -i '' -e 's|fan-flames-artifacts|kaisen-artifacts|g' \
          -e 's|fan-flames-task-brief|kaisen-task-brief|g' \
  plugins/workspace-jj/tests/test-kaisen-scripts.sh \
  plugins/workspace-jj/skills/fan-flames/SKILL.md
```

- [ ] **Step 5: Run both suites — they MUST pass**

```bash
bash plugins/workspace-jj/tests/test-kaisen-scripts.sh; echo "scripts exit: $?"
bash plugins/workspace-jj/tests/test-skill-paths.sh; echo "paths exit: $?"
```

Expected: script tests `22 passed, 0 failed`, `scripts exit: 0`. Path lint `3 passed, 0 failed`,
`paths exit: 0` — now resolving `../../scripts/kaisen-artifacts` and `../../scripts/kaisen-task-brief`.

- [ ] **Step 6: Confirm no stale script names remain**

```bash
grep -rn 'fan-flames-artifacts\|fan-flames-task-brief' plugins/ || echo "clean"
```

Expected: `clean`.

- [ ] **Step 7: Commit**

```bash
jj commit -m "refactor(workspace-jj): rename helper scripts to kaisen-*

fan-flames-task-brief resolved its sibling by name, so a pure move
would have left it calling a script that no longer exists. Line 31 is
edited, not just moved."
```

---

### Task 4: Delete the wrapper command and rename the skill to `kaisen` (defects B + A′)

Commands and skills share one namespace. `workspace-jj` declares both a command and a skill named
`fan-flames`; the command wins, and its whole body says *"Invoke the `workspace-jj:fan-flames`
skill"* — an instruction that resolves back to itself. The skill is unreachable.

The command is a six-line wrapper that sequences nothing. Deleting it breaks the collision and
lets the skill own the name. Its jj-safety preamble carries real value and moves into the skill.

**Files:**
- Delete: `plugins/workspace-jj/commands/fan-flames.md`
- Modify: `plugins/workspace-jj/skills/fan-flames/` → `plugins/workspace-jj/skills/kaisen/` (move)
- Modify: `plugins/workspace-jj/skills/kaisen/SKILL.md` (frontmatter + body)

**Interfaces:**
- Consumes: `scripts/kaisen-artifacts`, `scripts/kaisen-task-brief` from Task 3
- Produces: the skill `workspace-jj:kaisen` — Task 5 points `CLAUDE.md` and the project-setup
  template at this exact identifier.

- [ ] **Step 1: Move the skill directory and delete the wrapper**

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
mv plugins/workspace-jj/skills/fan-flames plugins/workspace-jj/skills/kaisen
rm plugins/workspace-jj/commands/fan-flames.md
```

`wave-reviewer.md` moves with the directory. The skill's `./wave-reviewer.md` pointer is unchanged
— same directory, same relative path.

- [ ] **Step 2: Rename the skill in frontmatter**

In `plugins/workspace-jj/skills/kaisen/SKILL.md`, replace:

```yaml
name: fan-flames
```

with:

```yaml
name: kaisen
```

- [ ] **Step 3: Absorb the deleted command's jj-safety preamble**

In `plugins/workspace-jj/skills/kaisen/SKILL.md`, immediately after the closing `---` of the
frontmatter, insert:

```markdown
**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents (jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands and `gh` CLI.**
```

- [ ] **Step 4: Rename the tool in the body**

```bash
sed -i '' -e "s|fan-flames'|kaisen's|g" -e 's|fan-flames|kaisen|g' \
  plugins/workspace-jj/skills/kaisen/SKILL.md
```

The possessive rule runs first for consistency with Task 5 (there it is load-bearing — "fan-flames"
ends in *s*, "kaisen" does not, so a naive substitution yields `kaisen'`). This body currently has
no `fan-flames'` occurrences, so the first rule is a no-op here; it is retained so the two tasks
cannot drift.

Neither rule touches `FAN OUT` / `FAN IN`, which are uppercase and stay literal.

- [ ] **Step 5: Verify the phase names survived**

```bash
grep -n '^## Phase 2\|^## Phase 5' plugins/workspace-jj/skills/kaisen/SKILL.md
```

Expected: `## Phase 2: FAN OUT 🪭 — Create Workspaces and Dispatch` and
`## Phase 5: FAN IN 🔥 — Reunify Changes`, both unchanged. Agents read these; they stay literal.

- [ ] **Step 6: Run the suites**

```bash
bash plugins/workspace-jj/tests/test-skill-paths.sh; echo "paths exit: $?"
bash plugins/workspace-jj/tests/test-model-selection-lint.sh; echo "model exit: $?"
bash plugins/workspace-jj/tests/test-kaisen-scripts.sh; echo "scripts exit: $?"
```

Expected: all exit 0. The path lint now resolves from `skills/kaisen/` and still finds
`../../scripts/kaisen-*`. The model lint globs recursively and follows the move automatically.

- [ ] **Step 7: Verify the collision is structurally gone**

```bash
ls plugins/workspace-jj/commands/
ls plugins/workspace-jj/skills/
```

Expected: `commands/` contains only `workspace-list.md`. `skills/` contains only `kaisen/`. No name
appears in both.

- [ ] **Step 8: Commit**

```bash
jj commit -m "fix(workspace-jj)!: delete the wrapper command, rename skill to kaisen

Commands and skills share one namespace. workspace-jj declared both a
command and a skill named fan-flames; the command won, and its entire
body said 'Invoke the workspace-jj:fan-flames skill' — an instruction
that resolved back to itself. The skill was unreachable.

Verified empirically: Skill(workspace-jj:fan-flames) returned the
command's text verbatim.

This explains the plugin's history. /fan-flames always worked because
the model hit the loop, abandoned the Skill tool, and read the file
from disk — which is why stale CACHE content was observed changing
behaviour even though the skill was never registered. The file was
always read, never loaded.

The command sequenced nothing, so deleting it is the fix: the skill
owns the name. Its jj-safety preamble moves into the skill body.
argument-hint and allowed-tools are command-only fields and are lost;
the flags are already in the skill's Flags table.

Renamed to kaisen: workspace-jj wraps jj, which IS Jujutsu, so
workspace-jj:kaisen reads as 'jujutsu kaisen'.

BREAKING: /fan-flames is now /kaisen."
```

---

### Task 5: Update cross-plugin references, docs, and the project-setup template

The name reaches four other plugins. One reference is functional: the `project-setup-jj` template
carries the superpowers override table and is **installed into user projects**. Left stale, every
project bootstrapped after this routes `subagent-driven-development` to a dead skill name.

The template is gated by a `hash:` marker — `/project-setup` compares the installed marker to the
template's and **skips when they match**. Editing the body without changing the hash means the fix
reaches nobody.

**Files:**
- Modify: `plugins/project-setup-jj/templates/CLAUDE.md.template` (lines 1 and 15)
- Modify: `CLAUDE.md:13`
- Modify: `plugins/workspace-jj/README.md` (incl. the `:107` design-spec link)
- Modify: `plugins/permission-gateway/scripts/permission-gate.sh:515`
- Modify: `plugins/permission-gateway/tests/test-permission-gate.sh:274`
- Modify: `plugins/project-setup-jj/scripts/jj-workspace-create.sh:21`
- Modify: `plugins/workspace-jj/scripts/jj-workspace-create.sh:21`
- Modify: `plugins/agent-helpers-jj/scripts/jj-agent-helpers.sh:37`
- Modify: `plugins/agent-helpers-jj/README.md`, `plugins/project-setup-jj/README.md`, `plugins/permission-gateway/README.md`

**Interfaces:**
- Consumes: the identifier `workspace-jj:kaisen` from Task 4
- Produces: nothing consumed later

- [ ] **Step 1: Retarget the design-spec link**

Gate: `grep -rn 'fan-flames' plugins/` must reach zero, but `workspace-jj/README.md:107` links to a
`docs/specs/` **filename** containing `fan-flames`, and `docs/` is frozen. Retarget the link.

In `plugins/workspace-jj/README.md` line 107, replace:

```markdown
See [design spec](../../docs/specs/2026-03-18-permission-gateway-and-fan-flames-design.md) for full details.
```

with:

```markdown
See [design spec](../../docs/specs/2026-07-15-kaisen-rename-and-collision-design.md) for full details.
```

- [ ] **Step 2: Rename across the remaining live files**

Three sites read `fan-flames' <word>` — a possessive. "fan-flames" ends in *s*, so its possessive
is a bare apostrophe; "kaisen" does not, so a naive substitution yields the ungrammatical
`kaisen' abort path`. Substituting the possessive **first** fixes this. Verified safe: no
`'fan-flames'` (apostrophe-quoted) string exists in `plugins/`, so the possessive rule cannot
corrupt a quoted token.

```bash
cd /Users/muloka/projects/sonder-hale/tools/claude-plugins
sed -i '' -e "s|workspace-jj:fan-flames|workspace-jj:kaisen|g" \
          -e "s|fan-flames'|kaisen's|g" \
          -e "s|fan-flames|kaisen|g" \
  CLAUDE.md \
  plugins/workspace-jj/README.md \
  plugins/workspace-jj/tests/test-model-selection-lint.sh \
  plugins/project-setup-jj/templates/CLAUDE.md.template \
  plugins/project-setup-jj/README.md \
  plugins/project-setup-jj/scripts/jj-workspace-create.sh \
  plugins/workspace-jj/scripts/jj-workspace-create.sh \
  plugins/permission-gateway/README.md \
  plugins/permission-gateway/scripts/permission-gate.sh \
  plugins/permission-gateway/tests/test-permission-gate.sh \
  plugins/agent-helpers-jj/README.md \
  plugins/agent-helpers-jj/scripts/jj-agent-helpers.sh
```

`test-model-selection-lint.sh` is in this list because its header comment reads *"fan-flames' Model
Selection table…"*. It is a test file, but the reference is prose about the tool, not a path.

- [ ] **Step 3: Verify the possessives and the skill path came out right**

```bash
grep -rn "kaisen' \|kaisen's " plugins/ | sed 's/^/  /'
ls plugins/workspace-jj/skills/kaisen/SKILL.md
```

Expected: every hit reads `kaisen's` — **none** reads `kaisen' ` with a bare apostrophe. The three
sites are `permission-gate.sh:515`, `test-permission-gate.sh:274`, and
`test-model-selection-lint.sh:4`. The `ls` must succeed: `test-permission-gate.sh:274` cites
`skills/kaisen/SKILL.md`, and that path must exist after Task 4's move.

- [ ] **Step 4: Recompute the template hash — the fix reaches nobody without this**

```bash
T=plugins/project-setup-jj/templates/CLAUDE.md.template
NEW=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$T" | sed '1d;$d' | md5 -q | cut -c1-8)
echo "new hash: $NEW"
```

(On Linux, use `md5sum | cut -c1-8` instead of `md5 -q | cut -c1-8`.)

Then replace line 1 of the template, substituting the printed value:

```markdown
<!-- jj-project-setup:start hash:<NEW> -->
```

Also add the recipe as the template's second line so the next editor can reproduce it:

```markdown
<!-- hash = md5 of the body between these markers, exclusive, first 8 hex chars -->
```

- [ ] **Step 5: Verify the hash actually changed and is reproducible**

```bash
T=plugins/project-setup-jj/templates/CLAUDE.md.template
head -2 "$T"
echo "recomputed: $(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$T" | sed '1d;$d' | md5 -q | cut -c1-8)"
```

Expected: the `hash:` in line 1 equals the recomputed value, and is **not** `f2f52fd2`. If it still
reads `f2f52fd2`, `/project-setup` will report "CLAUDE.md already up to date" and skip forever.

Note: adding the recipe comment on line 2 changes the body, so recompute **after** inserting it and
use that final value.

- [ ] **Step 6: Verify the routing target**

```bash
grep -n 'workspace-jj:kaisen' plugins/project-setup-jj/templates/CLAUDE.md.template CLAUDE.md
```

Expected: one hit in each — the superpowers override table now routes to the live skill.

- [ ] **Step 7: The gate — zero `fan-flames` anywhere in plugins/**

```bash
grep -rn 'fan-flames' plugins/ CLAUDE.md || echo "clean"
```

Expected: `clean`. Trust this gate over any file list — during spec review it, not the inventory,
surfaced the cross-plugin references.

- [ ] **Step 8: Run every suite**

```bash
for t in plugins/workspace-jj/tests/*.sh plugins/permission-gateway/tests/*.sh; do
  echo "=== $t"; bash "$t" | tail -1
done
```

Expected: `3 passed, 0 failed` (paths), `4 passed, 0 failed` (model), `22 passed, 0 failed`
(scripts), `=== Results: 133 passed, 0 failed ===` (permission gate).

- [ ] **Step 9: Commit**

```bash
jj commit -m "refactor: point every live reference at workspace-jj:kaisen

The name reached four other plugins. One was functional:
project-setup-jj's CLAUDE.md.template carries the superpowers override
table and is installed into user projects — left stale, every project
bootstrapped after the rename would route
subagent-driven-development to a dead skill name.

That template is gated by a hash marker: /project-setup compares the
installed marker to the template's and skips when they match. Editing
the body without rehashing means the fix reaches nobody — #84's lesson
one layer down: the template is keyed by hash, no rehash, no update.

The old hash f2f52fd2 was unreproducible by any md5 of the template —
a nonce, not a content hash. Replaced with a real content hash plus the
recipe, recorded in the template so the next editor can reproduce it.

workspace-jj/README.md's design-spec link is retargeted: its old target
FILENAME contained fan-flames, and docs/ is frozen as history.

docs/plans/ and docs/specs/ are untouched by design."
```

---

### Task 6: Version bumps — the ship gate

Per #84, the plugin cache is keyed by version string. Without a bump, `claude plugin update`
compares `0.1.1 == 0.1.1`, reports **"already at the latest version"**, and never re-fetches.
Everything above reaches nobody.

Bump only where behaviour changes. Comment-only edits do not need to ship.

**Files:**
- Modify: `plugins/workspace-jj/.claude-plugin/plugin.json`
- Modify: `plugins/project-setup-jj/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: every prior task
- Produces: nothing

- [ ] **Step 1: Bump `workspace-jj` to 0.1.2**

In `plugins/workspace-jj/.claude-plugin/plugin.json`, replace `"version": "0.1.1",` with
`"version": "0.1.2",`.

- [ ] **Step 2: Bump `project-setup-jj` to 0.1.1**

In `plugins/project-setup-jj/.claude-plugin/plugin.json`, replace `"version": "0.1.0",` with
`"version": "0.1.1",`.

- [ ] **Step 3: Verify both manifests parse and read the new versions**

```bash
for p in workspace-jj project-setup-jj peer-review-jj permission-gateway agent-helpers-jj commit-commands-jj; do
  printf "%-20s %s\n" "$p" "$(python3 -c "import json;print(json.load(open('plugins/$p/.claude-plugin/plugin.json'))['version'])")"
done
```

Expected: `workspace-jj 0.1.2`, `project-setup-jj 0.1.1`, `peer-review-jj 0.1.1`, and
`permission-gateway`, `agent-helpers-jj`, `commit-commands-jj` all `0.1.0` — comment-only edits,
nothing to ship.

- [ ] **Step 4: Commit**

```bash
jj commit -m "chore(plugins): bump workspace-jj to 0.1.2, project-setup-jj to 0.1.1

The cache is keyed by version string: without a bump, claude plugin
update compares equal versions, reports 'already at the latest
version', and never re-fetches. Everything in this PR would reach
nobody.

Bumped only where behaviour changes. permission-gateway and
agent-helpers-jj get comment-only edits — a comment that never ships is
harmless, and bumping for prose is churn."
```

---

## Post-merge verification

These gates cannot run before merge. **The static checks above do not prove B or C** — B was
invisible until the skill was invoked, and C is a *resolution* bug whose resolution only happens at
runtime, in the loaded context, which is the one place it has never been exercised.

- [ ] **Step 1: Ship it**

```bash
claude plugin marketplace update muloka-claude-plugins
claude plugin update workspace-jj@muloka-claude-plugins
claude plugin update project-setup-jj@muloka-claude-plugins
```

Expected: `updated from 0.1.1 to 0.1.2` and `updated from 0.1.0 to 0.1.1`. If either says "already
at the latest version", the bump did not land.

- [ ] **Step 2: Verify the cache by content, not by that message**

```bash
find ~/.claude/plugins/cache/muloka-claude-plugins/workspace-jj/0.1.2/skills -name 'SKILL.md'
grep -c 'kaisen' ~/.claude/plugins/cache/muloka-claude-plugins/workspace-jj/0.1.2/skills/kaisen/SKILL.md
```

Expected: `.../skills/kaisen/SKILL.md` exists and greps non-zero.

- [ ] **Step 3: Restart Claude Code, then prove B**

Invoke `Skill(workspace-jj:kaisen)`.

Expected: the **skill body** — the phase overview, FAN OUT/FAN IN, the Flags table. **Not** a
command. If it returns a short "Invoke the … skill" wrapper, B is not fixed.

- [ ] **Step 4: Prove C at runtime**

From the loaded skill, resolve `../../scripts/kaisen-artifacts` against the base directory the
Skill tool announced, and run it.

Expected: it prints an artifacts path under `/tmp/jj-workspaces/<repo>/artifacts`. A file-exists
check does not substitute for this — C is about resolution, and only a run proves it.

- [ ] **Step 5: Prove the template reaches projects**

Run `/project-setup` in a project whose CLAUDE.md carries the old `hash:f2f52fd2` marker.

Expected: the section is **replaced**, and the CLAUDE.md override table then routes
`subagent-driven-development` to `workspace-jj:kaisen`. If it reports "CLAUDE.md already up to
date", the hash did not change.

- [ ] **Step 6: Prove D**

Check the `validate` job on this PR.

Expected: **green**. This PR deletes two `.md` files matching CI's filter, so it is D's own test
case. A red job with `ENOENT` means the filter did not land.
