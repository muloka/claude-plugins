---
name: requesting-change-review
description: |
  Phase 1 of /peer-review. Use when dispatching generalist reviewers for a jj change.
  Triggers after completing work, before committing, or when reviewing a change.
---

# Requesting Change Review

Phase 1 of `/peer-review`: assess the change, partition files, dispatch generalist reviewers, collect structured findings.

## Constants

```
LINES_PER_GENERALIST = 300
```

## Step 1: Assess Change Size

Get total lines changed:

```bash
jj log -r <rev> --no-graph -T 'self.diff().stat().total_added() ++ " " ++ self.diff().stat().total_removed()'
```

Get per-file line counts for partitioning:

```bash
jj log -r <rev> --no-graph -T 'self.diff().stat().files().map(|entry| "{ \"path\": " ++ entry.path().display().escape_json() ++ ", \"lines_added\": " ++ entry.lines_added() ++ ", \"lines_removed\": " ++ entry.lines_removed() ++ " }\n")'
```

Sum `lines_added + lines_removed` across all files for the total.

## Step 2: Decide Generalist Count

- 1 generalist per ~`LINES_PER_GENERALIST` lines changed
- Minimum 1 generalist
- Formula: `max(1, ceil(total_lines / LINES_PER_GENERALIST))`

## Step 3: Partition Files

Split changed files across generalists using these rules in priority order:

1. **Single file > LINES_PER_GENERALIST lines** → gets its own generalist
2. **Directory affinity**: files in the same directory stay together when possible
3. **Line count balance**: partitions should be roughly equal in total lines changed
4. **When affinity and balance conflict**: prefer affinity (reviewing related files together produces better findings)

## Step 4: Package Context for Each Generalist

Each generalist receives a prompt with:

- **Scope**: which files are theirs and only theirs
- **How to read**: `jj diff -r <rev>` scoped to their files, plus permission to read full files for surrounding context
- **Guidelines**: relevant CLAUDE.md content inline (read CLAUDE.md files from the project root and any subdirectories containing changed files)
- **Change context**: revision, description, change metadata from `jj log -r <rev> --no-graph -T 'json(self) ++ "\n"'`
- **Output schema**: the generalist response JSON schema (from the change-reviewer agent spec)

## Step 5: If --track Enabled

### Resumability Detection

Check for existing review state first:

```bash
jj log -r 'description("review: <change-id>")' --no-graph -T 'self.change_id().short(8)'
```

If found, check which files are already squashed (reviewed) by comparing `jj diff --stat` on the working copy. Only dispatch generalists for files still in the working copy. Skip setup below.

### Setup (first run, only if no existing review state)

```bash
# 1. Duplicate the target change
DUPLICATE=$(jj duplicate <revision> 2>&1 | sed -n 's/.*as \([a-z]*\) .*/\1/p')

# 2. Move working copy to the duplicate
jj edit $DUPLICATE

# 3. Insert an empty parent before the duplicate
jj new --no-edit --insert-before @

# 4. Identify the new parent
REVIEWED_PARENT=$(jj log -r '@-' --no-graph -T 'self.change_id().short(8)')

# 5. Tag the empty parent for detection
jj describe -r $REVIEWED_PARENT -m "review: <change-id>"
```

## Step 6: Dispatch Generalists

- Use the Agent tool to dispatch generalists in parallel
- Each generalist is a `change-reviewer` agent (subagent_type: `change-reviewer`)
- Include the jj-only directive in each agent prompt
- Collect all JSON responses

Example dispatch (single generalist):

```
Agent(
  subagent_type: "change-reviewer",
  prompt: "Review these files in revision <rev>: <file list>. <context>. <guidelines>. Return structured JSON."
)
```

For multiple generalists, dispatch all in a single message with parallel Agent calls.

### After Each Generalist Completes (if --track)

Squash clean files (no findings) into the reviewed parent:

```bash
jj squash --into $REVIEWED_PARENT <files with no findings>
```

This shrinks the working copy diff to show only unreviewed files.

## Handoff

Pass the collected JSON responses (array of generalist results) to the receiving skill for aggregation and presentation.
