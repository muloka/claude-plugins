# peer-review-jj Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `peer-review-jj` Claude Code plugin — a unified change review system with one command, two skills, one generalist agent, and an evolvable specialist lifecycle.

**Architecture:** Two-phase pipeline (requesting → receiving). The `/peer-review` command assesses the change, dispatches scaled generalists, aggregates findings with severity tiers, and recommends specialists. All output is structured JSON internally, rendered as markdown locally or posted to GitHub via `--post`.

**Tech Stack:** Claude Code plugin system (markdown commands, skills, agents with YAML frontmatter), bash hooks, jj CLI, gh CLI.

**Spec:** `docs/peer-review-jj/2026-03-16-peer-review-jj-design.md`

**VCS workflow:** This project uses jj. Each task creates a new change via `jj new` before starting work, then `jj describe -m "..."` to set the description. Each task is a separate jj change.

---

## Chunk 1: Plugin Scaffold, Scripts, and Agent

### Task 1: Create plugin directory structure

**Files:**
- Create: `plugins/peer-review-jj/.claude-plugin/plugin.json`
- Create: `plugins/peer-review-jj/commands/` (directory)
- Create: `plugins/peer-review-jj/skills/` (directory)
- Create: `plugins/peer-review-jj/agents/` (directory)
- Create: `plugins/peer-review-jj/scripts/` (directory)

- [ ] **Step 1: Create directories**

```bash
mkdir -p plugins/peer-review-jj/.claude-plugin
mkdir -p plugins/peer-review-jj/commands
mkdir -p plugins/peer-review-jj/skills
mkdir -p plugins/peer-review-jj/agents
mkdir -p plugins/peer-review-jj/scripts
```

- [ ] **Step 2: Write plugin.json**

Create `plugins/peer-review-jj/.claude-plugin/plugin.json`:

```json
{
  "name": "peer-review-jj",
  "description": "Unified change review for jj repos — generalist-first with emergent specialists, two-phase pipeline, structured findings",
  "author": {
    "name": "muloka",
    "email": "muloka@users.noreply.github.com"
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/block-raw-git.sh"
          },
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/block-review-markers.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 3: Verify directory structure**

```bash
find plugins/peer-review-jj -type f -o -type d | sort
```

Expected: all directories and `plugin.json` present.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(peer-review-jj): scaffold plugin directory structure"
jj new
```

---

### Task 2: Create hook scripts

**Files:**
- Create: `plugins/peer-review-jj/scripts/block-raw-git.sh`
- Create: `plugins/peer-review-jj/scripts/block-review-markers.sh`

**Reference:** Copy `block-raw-git.sh` from `plugins/code-review-jj/scripts/block-raw-git.sh` — it's identical across all jj plugins.

- [ ] **Step 1: Copy block-raw-git.sh**

```bash
cp plugins/code-review-jj/scripts/block-raw-git.sh plugins/peer-review-jj/scripts/
chmod +x plugins/peer-review-jj/scripts/block-raw-git.sh
```

- [ ] **Step 2: Write block-review-markers.sh**

Create `plugins/peer-review-jj/scripts/block-review-markers.sh`:

```bash
#!/usr/bin/env bash
# PreToolUse hook: Warn if REVIEW(peer): markers found in code being committed
# Safety backstop for future annotation features

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')

# Only check jj commit/squash operations
if echo "$command" | grep -qE '(jj\s+(commit|squash))'; then
  # Check staged changes for review markers
  if jj diff 2>/dev/null | grep -q 'REVIEW(peer):'; then
    cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "BLOCKED: Found REVIEW(peer): markers in code being committed. These are review annotations that should not land in the codebase. Remove them before committing."
  }
}
EOF
    exit 0
  fi
fi

exit 0
```

```bash
chmod +x plugins/peer-review-jj/scripts/block-review-markers.sh
```

- [ ] **Step 3: Verify scripts are executable**

```bash
ls -la plugins/peer-review-jj/scripts/
```

Expected: both files with execute permission.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(peer-review-jj): add hook scripts for git blocking and review marker lint"
jj new
```

---

### Task 3: Create the generalist agent (`change-reviewer`)

**Files:**
- Create: `plugins/peer-review-jj/agents/change-reviewer.md`
- Reference: `plugins/pr-review-toolkit-jj/agents/code-reviewer.md` (for agent frontmatter patterns)
- Reference: `plugins/code-review-jj/commands/code-review.md` (for false positive list)
- Reference: `~/.claude/plugins/cache/claude-plugins-official/superpowers/5.0.2/skills/requesting-code-review/code-reviewer.md` (for review checklist and output format)

The generalist agent is the core of the plugin. It reviews changes for code quality, architecture, testing, requirements, and guideline compliance, then returns structured JSON with findings, specialist recommendations, and a partition verdict.

- [ ] **Step 1: Write change-reviewer.md**

Create `plugins/peer-review-jj/agents/change-reviewer.md` with:

**Frontmatter:**
- `name: change-reviewer`
- `description:` Trigger examples for reviewing changes (after completing work, before committing, when asked to review)
- `model: sonnet` (generalist runs frequently, sonnet balances quality and cost)
- `color: blue`

**System prompt content (in order):**

1. **jj-only directive** — the standard block copied from existing agents
2. **Role** — "You are a change reviewer. You review jj changes for production readiness. You return structured JSON findings."
3. **What to review** — code quality, architecture, testing, requirements, CLAUDE.md compliance (from spec section "What It Reviews")
4. **What NOT to review** — don't run tests/build/lint, don't review unchanged code, don't flag style unless CLAUDE.md requires it, don't deep-dive specialist concerns (from spec section "What It Does NOT Do")
5. **False positive awareness** — the full list from the spec (pre-existing issues, linter-catchable, pedantic nitpicks, unmodified lines, intentional changes, lint-ignore silenced)
6. **Confidence calibration** — the 0-100 scale with >= 80 threshold (from spec)
7. **Specialist recommendation trigger** — when to flag for specialists instead of analyzing deeply (from spec)
8. **File modification discipline** — "Do not modify source files. Review is read-only." (from spec)
9. **Output schema** — the full JSON response schema from the spec:
   ```json
   {
     "files_reviewed": [...],
     "findings": [{ "severity", "confidence", "description", "reason", "file", "line_range", "guideline", "fix_hint" }],
     "specialist_recommendations": [{ "concern", "files", "line_ranges", "rationale" }],
     "partition_verdict": "yes|no|with_fixes",
     "verdict_reasoning": "one sentence"
   }
   ```
10. **Concern type enum** — the full list. `Other` in JSON: `{"concern": "Other", "other_description": "description of the concern"}`
11. **Specialist refinement proposals** — when the generalist encounters a pattern that relates to an existing project specialist, it should note this in its response as a proposed refinement (not edit the specialist directly). The receiving skill handles appending proposals to the specialist's `## Proposed Refinements` section.

Read the referenced files to build the full prompt. The agent should be ~150-200 lines of markdown.

- [ ] **Step 2: Verify agent frontmatter parses**

Read the file back and confirm YAML frontmatter is valid (name, description, model, color fields present).

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(peer-review-jj): add change-reviewer generalist agent"
jj new
```

---

## Chunk 2: Skills

### Task 4: Create requesting-change-review skill

**Files:**
- Create: `plugins/peer-review-jj/skills/requesting-change-review.md`
- Reference: spec sections "Requesting Skill" and "Progress Tracking"

The requesting skill handles phase 1: assess the change, decide generalist count, partition files, package context, dispatch generalists, collect JSON responses.

- [ ] **Step 1: Write requesting-change-review.md**

Create `plugins/peer-review-jj/skills/requesting-change-review.md` with:

**Frontmatter:**
- `name: requesting-change-review`
- `description:` When to trigger (after completing work, before committing, when reviewing a change)

**Skill content (in order):**

1. **Purpose** — "Phase 1 of /peer-review: assess the change, partition files, dispatch generalist reviewers, collect structured findings."

2. **Step 1: Assess change size**
   - Total lines: `jj log -r <rev> --no-graph -T 'self.diff().stat().total_added() ++ " " ++ self.diff().stat().total_removed()'`
   - Per-file counts: the full template from the spec (line 143)
   - Sum `lines_added + lines_removed` for total

3. **Step 2: Decide generalist count**
   - 1 generalist per ~300 lines changed, minimum 1
   - The 300-line constant should be defined once at the top of the skill for easy calibration

4. **Step 3: Partition files**
   - Rules in priority order (from spec):
     - Single file > 300 lines → own generalist
     - Directory affinity: same directory stays together
     - Line count balance: roughly equal partitions
     - Affinity wins over balance when they conflict

5. **Step 4: Package context for each generalist**
   - Prompt template (not JSON payload):
     - Scope: which files are theirs
     - How to read: `jj diff -r <rev>` scoped to their files, permission to read full files
     - Guidelines: relevant CLAUDE.md content inline
     - Change context: revision, description, metadata
     - Output schema: the response JSON schema

6. **Step 5: Dispatch generalists**
   - Use Agent tool to dispatch in parallel
   - Each generalist is a `change-reviewer` agent
   - Collect all JSON responses

7. **Step 6: If --track enabled**
   - Setup sequence from spec (duplicate, edit, insert parent, describe with `review: <change-id>`)
   - After each generalist completes, squash its clean files into the reviewed parent
   - Detection for resumability: search for `review: <change-id>` description

8. **Handoff** — pass collected JSON responses to the receiving skill

- [ ] **Step 2: Verify skill frontmatter**

Read back and confirm YAML is valid.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(peer-review-jj): add requesting-change-review skill"
jj new
```

---

### Task 5: Create receiving-change-review skill

**Files:**
- Create: `plugins/peer-review-jj/skills/receiving-change-review.md`
- Reference: spec sections "Receiving Skill", "Specialist Lifecycle", "Specialist Memory"

The receiving skill handles phase 2: aggregate generalist findings, deduplicate, reconcile verdicts, present results, manage specialist dispatch and emergence.

- [ ] **Step 1: Write receiving-change-review.md**

Create `plugins/peer-review-jj/skills/receiving-change-review.md` with:

**Frontmatter:**
- `name: receiving-change-review`
- `description:` When to trigger (after generalist dispatch completes, when processing review findings)

**Skill content (in order):**

1. **Purpose** — "Phase 2 of /peer-review: aggregate findings, present results, manage specialist lifecycle."

2. **Step 1: Verify coverage**
   - Union of `files_reviewed` across all generalist responses should equal the full file set
   - If gaps: report which files were missed

3. **Step 2: Deduplicate findings**
   - Same file + overlapping line range = candidate duplicate
   - Make semantic judgment on whether descriptions refer to the same issue
   - Keep the higher-confidence finding when deduplicating

4. **Step 3: Reconcile verdicts**
   - Any `no` → overall `no`
   - Any `with_fixes` → overall `with_fixes`
   - All `yes` → overall `yes`
   - Preserve per-partition verdicts in output

5. **Step 4: Aggregate specialist recommendations**
   - Group by concern type (enum-normalized)
   - Merge file lists for same concern type across generalists
   - Deduplicate line ranges

6. **Step 5: Check history for specialist emergence**
   - Read `.claude/peer-review/history.jsonl` if it exists
   - Count distinct `pattern` values per concern `type` across entries
   - If any concern type has 3+ distinct patterns: prepare emergence prompt
   - Present prompt to user: "[peer-review] <type> flagged in N reviews. Distinct patterns: <list>. Create a project specialist? (y/n)"

7. **Step 6: Append to history**
   - Note: emergence check (Step 5) runs before append so the current review's patterns don't count toward their own emergence threshold
   - Create `.claude/peer-review/` directory if it doesn't exist (`mkdir -p`)
   - Append one JSONL line to `.claude/peer-review/history.jsonl` using `tee -a` (not Write, which would overwrite)

8. **Step 7: Present results**
   - Format per the output template in the spec (Findings by severity, Verdict, Specialist Recommendations, Actions)
   - If `--post`: format as GitHub PR comment via `gh pr comment`
   - If `--json`: output raw JSON
   - If no PR found with `--post`: error message from spec

9. **Step 8: If specialist emergence approved**
   - Create `.claude/peer-review/specialists/<concern-type>.md`
   - Seed with accumulated patterns, CLAUDE.md guidelines, scoped prompt
   - Follow the scaffolding template from the spec

10. **Step 9: If --deep specified**
    - Dispatch specialists for flagged concerns
    - Discovery order: project → user-global → plugin built-in
    - Scope each specialist to flagged locations only
    - Include specialist memory summary (prior patterns with recency, framed as context not checklist)
    - Aggregate specialist findings into final output

11. **Specialist refinement proposals**
    - If a generalist proposes a refinement to an existing specialist, append it to the specialist's `## Proposed Refinements` section
    - Format: `- [YYYY-MM-DD] change-reviewer flagged: "<proposal>" (seen in <file>:<lines>)`
    - Only humans promote proposals into the active prompt

12. **Verification protocol**
    - Don't blindly implement findings
    - Push back on false positives with technical reasoning
    - Flag findings that contradict project decisions

- [ ] **Step 2: Verify skill frontmatter**

Read back and confirm YAML is valid.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(peer-review-jj): add receiving-change-review skill"
jj new
```

---

## Chunk 3: Command, Deprecation, and Testing

### Task 6: Create peer-review command

**Files:**
- Create: `plugins/peer-review-jj/commands/peer-review.md`
- Reference: spec section "Command Flow"
- Reference: `plugins/code-review-jj/commands/code-review.md` (for command frontmatter patterns)

The command is the single entry point that orchestrates both skills.

- [ ] **Step 1: Write peer-review.md**

Create `plugins/peer-review-jj/commands/peer-review.md` with:

**Frontmatter:**
```yaml
---
description: "Review a jj change for production readiness"
argument-hint: "[revision] [--deep <concerns>] [--track] [--post] [--json] [--discard]"
allowed-tools:
  - Agent
  - Bash(jj log:*)
  - Bash(jj status:*)
  - Bash(jj diff:*)
  - Bash(jj duplicate:*)
  - Bash(jj edit:*)
  - Bash(jj new:*)
  - Bash(jj describe:*)
  - Bash(jj squash:*)
  - Bash(jj abandon:*)
  - Bash(gh pr view:*)
  - Bash(gh pr comment:*)
  - Bash(gh pr list:*)
  - Bash(mkdir:*)
  - Bash(tee -a:*)
  - Read
  - Write
  - Glob
  - Grep
---
```

**Command content (in order):**

1. **jj-only directive** — the standard block

2. **Context section** with dynamic commands:
   - Current change: `!jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
   - Changed files: `!jj diff --stat`

3. **Argument parsing**
   - `$ARGUMENTS` parsing: extract revision (default `@`), flags (`--deep`, `--track`, `--post`, `--json`, `--discard`)
   - `--deep` accepts space-separated lowercase aliases mapping to enum values

4. **Orchestration flow** (the 8 steps from the spec):
   - Step 1: Assess change size using jj templates
   - Step 2: If `--track`, set up duplicate+squash per the spec setup sequence
   - Step 3: Calculate generalist count (1 per ~300 lines, min 1)
   - Step 4: Partition files per the priority rules
   - Step 5: Invoke requesting skill — dispatch generalists
   - Step 6: Invoke receiving skill — aggregate and present
   - Step 7-8: Handled by receiving skill (history append, emergence check, presentation)

5. **Cleanup section**
   - If `--discard`: abandon review state
   - If `--track` and no `--discard`: check if target merged to trunk, auto-abandon if so

6. **Output format** — the template from the spec

- [ ] **Step 2: Verify command frontmatter**

Read back and confirm YAML frontmatter is valid and all required fields are present.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat(peer-review-jj): add /peer-review command"
jj new
```

---

### Task 7: Remove deprecated plugins

**Files:**
- Remove: `plugins/code-review-jj/` (entire directory)
- Remove: `plugins/pr-review-toolkit-jj/` (entire directory)
- Remove: `plugins/feature-dev-jj/` (entire directory)

- [ ] **Step 1: Verify the deprecated plugins exist**

```bash
ls -d plugins/code-review-jj plugins/pr-review-toolkit-jj plugins/feature-dev-jj
```

- [ ] **Step 2: Remove all three**

```bash
rm -rf plugins/code-review-jj
rm -rf plugins/pr-review-toolkit-jj
rm -rf plugins/feature-dev-jj
```

- [ ] **Step 3: Verify removal**

```bash
ls plugins/
```

Expected: `code-review-jj`, `pr-review-toolkit-jj`, and `feature-dev-jj` are gone. Other plugins remain.

- [ ] **Step 4: Commit**

```bash
jj describe -m "chore: remove deprecated code-review-jj, pr-review-toolkit-jj, feature-dev-jj plugins

Replaced by peer-review-jj. See docs/peer-review-jj/2026-03-16-peer-review-jj-design.md."
jj new
```

---

### Task 8: Add README

**Files:**
- Create: `plugins/peer-review-jj/README.md`

- [ ] **Step 1: Write README.md**

Create `plugins/peer-review-jj/README.md` with:
- Plugin name and one-line description
- Usage: `/peer-review`, `/peer-review <revision>`, `/peer-review --deep errors types`, `/peer-review --track`, `/peer-review --post`
- Architecture summary: two-phase pipeline, generalist-first, emergent specialists
- Link to design doc
- Note about jj-only (no raw git)

Keep it concise — under 50 lines. The design doc has the full details.

- [ ] **Step 2: Commit**

```bash
jj describe -m "docs(peer-review-jj): add README"
jj new
```

---

### Task 9: Integration verification

**No files created.** This task verifies the plugin works end-to-end.

- [ ] **Step 1: Verify plugin structure is complete**

```bash
find plugins/peer-review-jj -type f | sort
```

Expected files:
```
plugins/peer-review-jj/.claude-plugin/plugin.json
plugins/peer-review-jj/README.md
plugins/peer-review-jj/agents/change-reviewer.md
plugins/peer-review-jj/commands/peer-review.md
plugins/peer-review-jj/scripts/block-raw-git.sh
plugins/peer-review-jj/scripts/block-review-markers.sh
plugins/peer-review-jj/skills/receiving-change-review.md
plugins/peer-review-jj/skills/requesting-change-review.md
```

- [ ] **Step 2: Verify all frontmatter is valid YAML**

Read each `.md` file and confirm the YAML frontmatter between `---` delimiters is syntactically valid.

- [ ] **Step 3: Verify plugin.json is valid JSON**

```bash
jq . plugins/peer-review-jj/.claude-plugin/plugin.json
```

Expected: valid JSON output, no errors.

- [ ] **Step 4: Verify scripts are executable**

```bash
test -x plugins/peer-review-jj/scripts/block-raw-git.sh && echo "OK" || echo "FAIL"
test -x plugins/peer-review-jj/scripts/block-review-markers.sh && echo "OK" || echo "FAIL"
```

Expected: both OK.

- [ ] **Step 5: Verify deprecated plugins are removed**

```bash
test ! -d plugins/code-review-jj && echo "OK" || echo "FAIL: code-review-jj still exists"
test ! -d plugins/pr-review-toolkit-jj && echo "OK" || echo "FAIL: pr-review-toolkit-jj still exists"
test ! -d plugins/feature-dev-jj && echo "OK" || echo "FAIL: feature-dev-jj still exists"
```

Expected: all OK.

- [ ] **Step 6: Commit final state**

```bash
jj describe -m "feat(peer-review-jj): complete v1 plugin implementation

Replaces code-review-jj, pr-review-toolkit-jj, and feature-dev-jj.
Two-phase pipeline with generalist-first architecture and emergent specialists.
See docs/peer-review-jj/2026-03-16-peer-review-jj-design.md for full design."
```
