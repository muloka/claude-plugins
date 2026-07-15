---
name: receiving-change-review
description: |
  Phase 2 of /peer-review. Use after generalist dispatch completes to aggregate findings,
  present results, and manage specialist lifecycle.
---

# Receiving Change Review

Phase 2 of `/peer-review`: aggregate findings, present results, manage specialist lifecycle.

## Step 1: Verify Coverage

Union of `files_reviewed` across all generalist responses should equal the full file set from the change.

If gaps exist: report which files were missed. Consider re-dispatching for missed files.

## Step 2: Deduplicate Findings

- Same file + overlapping line range = candidate duplicate
- Make a semantic judgment on whether descriptions refer to the same issue
- Keep the higher-confidence finding when deduplicating
- Preserve both if they describe genuinely different issues at overlapping locations

## Step 3: Reconcile Verdicts

| Condition | Overall Verdict |
|---|---|
| Any `no` | `no` |
| Any `with_fixes` (no `no`) | `with_fixes` |
| All `yes` | `yes` |

Preserve per-partition verdicts in the output so users can see which areas are clean vs. need fixes.

## Step 4: Aggregate Specialist Recommendations

- Group by concern type (enum-normalized)
- Merge file lists for the same concern type across generalists
- Deduplicate line ranges

## Step 5: Check History for Specialist Emergence

**This step runs BEFORE appending the current review to history** (so the current review's patterns don't count toward their own emergence threshold).

1. Read `.claude/peer-review/history.jsonl` if it exists
2. Count distinct `pattern` values per concern `type` across entries
3. If any concern type has 3+ distinct patterns: prepare emergence prompt

Present prompt to user:

```
[peer-review] "<type>" flagged in N reviews for this project.
  Distinct patterns: <pattern1>, <pattern2>, <pattern3>.
Create a project specialist? (y/n)
```

Three occurrences of the same pattern is repetition, not emergence. Three *different* manifestations of a concern type across reviews — that's emergence.

## Step 6: Append to History

1. Create `.claude/peer-review/` directory if needed: `mkdir -p .claude/peer-review`
2. Append one JSONL line using `tee -a` (not Write, which would overwrite):

```bash
echo '{"timestamp":<unix>,"revision":"<short>","files_reviewed":[...],"findings_count":{"critical":N,"important":N,"minor":N},"concerns":[{"type":"<enum>","pattern":"<description>","files":[...],"line_ranges":[...]}],"verdict":"<verdict>"}' | tee -a .claude/peer-review/history.jsonl > /dev/null
```

## Step 7: Present Results

### Default (local) format:

```
## Peer Review: <change-id short>

### Findings
#### Critical (N)
- [change-reviewer] description — file:line

#### Important (N)
- [change-reviewer] description — file:line

#### Minor (N)
- [change-reviewer] description — file:line

### Verdict
Ready to merge: Yes / No / With fixes
Reasoning: <one sentence>

### Specialist Recommendations
- **error-handling**: 3 catch blocks in src/api/client.rs (lines 45-90, 120-135)
- **type-design**: New SessionState enum in src/types.rs

### Actions
- /peer-review --deep errors    # dispatch recommended specialist
- /peer-review --post           # post findings to GitHub PR
```

### GitHub (`--post`) format:

Format as a PR comment via `gh pr comment`. If no open PR found:

```
Error: No open PR found for bookmark '<name>'. Create one first or omit --post.
```

### JSON (`--json`) format:

Output raw JSON — the aggregated response with all findings, verdicts, and recommendations.

## Step 8: If Specialist Emergence Approved

Create `.claude/peer-review/specialists/<concern-type>.md` seeded with:

```markdown
---
name: <concern-type>
description: Project specialist for <concern-type> patterns
model: sonnet
---

## Role

You are a specialist reviewer for <concern-type> issues. You review specific files and line ranges flagged by the generalist reviewer.

## Patterns Observed in This Project

<list of accumulated distinct patterns from history with file references>

## Relevant Guidelines

<applicable CLAUDE.md rules>

## Review Focus

Analyze the flagged locations for <concern-type> issues. Return structured JSON findings using the same schema as the generalist, but with deeper analysis for your specialty.

## Proposed Refinements

(Generalist proposals appear here. Only humans promote them into the active prompt.)
```

## Step 9: If --deep Specified

Dispatch specialists for flagged concerns:

1. **Discovery order**: project (`.claude/peer-review/specialists/`) → user-global (`~/.claude/peer-review/specialists/`) → plugin built-in (`peer-review-jj/agents/`)
2. First match for a concern type wins — no merge, no inheritance
3. Scope each specialist to flagged locations only (specific files and line ranges)
4. Include specialist memory summary — prior patterns with recency, framed as context not checklist:

> "Patterns previously observed in this project (for context, not as a checklist): broad exception types (3x, last seen 2026-02-10), missing error context in retry paths (2x, last seen 2026-03-01)."

5. Aggregate specialist findings into final output

## Specialist Refinement Proposals

If a generalist proposes a refinement to an existing specialist, append it to the specialist's `## Proposed Refinements` section:

```markdown
- [YYYY-MM-DD] change-reviewer flagged: "<proposal>" (seen in <file>:<lines>)
```

Use `tee -a` or similar append operation. Only humans promote proposals into the active prompt.

## Verification Protocol

- Do NOT blindly implement findings
- Push back on false positives with technical reasoning
- Flag findings that contradict project decisions (CLAUDE.md, architectural choices)
- This applies whether a human or an orchestrating agent is acting on findings
