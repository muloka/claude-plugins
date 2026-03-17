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

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Do not run `ls .git`, `git log`, `git remote -v` or similar to detect repo state. Always use jj equivalents (jj log, jj status, jj diff, etc.). The only exceptions are `jj git` subcommands (e.g. `jj git push`, `jj git fetch`) and `gh` CLI for GitHub operations.**

**When spawning sub-agents, you MUST include this directive in every agent prompt: "CRITICAL: You MUST NOT use ANY raw git commands — not even for context discovery. This includes git checkout, git commit, git diff, git log, git status, git add, git branch, git blame, git remote, git rev-parse, git config, git show, git fetch, git pull, git push, git merge, git rebase, git stash, git reset, git tag, or any other `git` invocation. Always use jj equivalents (jj file annotate, jj log, jj diff, jj status, etc.). The only exceptions are `jj git` subcommands and `gh` CLI."**

## Context

- Current change (JSON): !`jj log -r @ --no-graph -T 'json(self) ++ "\n"'`
- Changed files: !`jj diff --stat`

## Argument Parsing

Parse `$ARGUMENTS` to extract:

- **revision**: First non-flag argument (default: `@`)
- **--deep <concerns>**: Space-separated lowercase aliases for specialist dispatch
  - `errors` → `ErrorHandling`
  - `types` → `TypeDesign`
  - `tests` → `TestCoverage`
  - `comments` → `CommentAccuracy`
  - `simplify` → `CodeSimplification`
  - `security` → `Security`
  - `perf` → `Performance`
  - `concurrency` → `Concurrency`
- **--track**: Enable progress tracking via duplicate+squash
- **--post**: Post findings to GitHub PR
- **--json**: Output raw JSON
- **--discard**: Abandon review state after completion

## Orchestration

### Step 1: Assess Change Size

```bash
jj log -r <rev> --no-graph -T 'self.diff().stat().total_added() ++ " " ++ self.diff().stat().total_removed()'
```

Get per-file counts:

```bash
jj log -r <rev> --no-graph -T 'self.diff().stat().files().map(|entry| "{ \"path\": " ++ entry.path().display().escape_json() ++ ", \"lines_added\": " ++ entry.lines_added() ++ ", \"lines_removed\": " ++ entry.lines_removed() ++ " }\n")'
```

### Step 2: If --track, Set Up Progress Tracking

Check for existing review state first:

```bash
jj log -r 'description("review: <change-id>")' --no-graph -T 'self.change_id().short(8)'
```

If found, resume from existing state — only dispatch for unreviewed files. Skip setup below.

If not found, set up:

```bash
# Duplicate the target change
DUPLICATE=$(jj duplicate <revision> 2>&1 | sed -n 's/.*as \([a-z]*\) .*/\1/p')

# Move working copy to the duplicate
jj edit $DUPLICATE

# Insert an empty parent before the duplicate
jj new --no-edit --insert-before @

# Identify the new parent
REVIEWED_PARENT=$(jj log -r '@-' --no-graph -T 'self.change_id().short(8)')

# Tag for detection
jj describe -r $REVIEWED_PARENT -m "review: <change-id>"
```

### Step 3: Calculate Generalist Count

```
LINES_PER_GENERALIST = 300
generalist_count = max(1, ceil(total_lines / LINES_PER_GENERALIST))
```

### Step 4: Partition Files

Priority rules:
1. Single file > 300 lines changed → own generalist
2. Directory affinity: same directory stays together
3. Line count balance: roughly equal partitions
4. Affinity wins over balance when they conflict

### Step 5: Invoke Requesting Skill

Follow the `requesting-change-review` skill:
- Package context for each generalist
- Dispatch `change-reviewer` agents in parallel via the Agent tool
- Collect structured JSON responses

### Step 6: Invoke Receiving Skill

Follow the `receiving-change-review` skill:
- Verify coverage
- Deduplicate findings
- Reconcile verdicts
- Aggregate specialist recommendations
- Check history for specialist emergence (before appending)
- Append to history
- Present results

### Step 7: Handle --deep

If `--deep` specified, the receiving skill dispatches specialists:
- Discovery order: project → user-global → plugin built-in
- Scope to flagged locations only
- Aggregate specialist findings into final output

### Step 8: Present and Clean Up

**Output** per the format specified by flags:
- Default: local markdown output
- `--post`: GitHub PR comment via `gh pr comment`
- `--json`: Raw structured JSON

**Cleanup:**
- If `--discard`: abandon review state (`jj abandon` the review commits)
- If `--track` and no `--discard`: check if target merged to trunk
  ```bash
  jj log -r '<change-id> & trunk()' --no-graph -T '"merged"'
  ```
  If merged, auto-abandon review commits — the review is irrelevant once the change lands
