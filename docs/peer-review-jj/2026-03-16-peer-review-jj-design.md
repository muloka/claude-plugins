# peer-review-jj — Change Review Plugin for jj

## Context

Code review tooling in this repo is fragmented across three plugins (`code-review-jj`, `pr-review-toolkit-jj`, `feature-dev-jj`) and two superpowers skills (`requesting-code-review`, `receiving-code-review` — part of the [Claude Code superpowers plugin](https://github.com/anthropics/claude-code-plugins), not this repo). The plugins have machinery but no protocol. The superpowers skills have protocol but no machinery. None of them track review progress, coordinate multiple reviewers, or learn from repeated patterns.

`peer-review-jj` unifies these into a single plugin with one command, two skills, and an evolvable specialist system. It reviews *changes* (jj-native), not pull requests (GitHub-specific). PRs are one possible output destination, not the organizing concept.

Inspired by [Gesoff's duplicate+squash review technique](https://ben.gesoff.uk/posts/reviewing-large-changes-with-jj/) and designed for future integration with [jjp](../../../jjp/docs/2026-03-06-jjp-design.md) CRDT-backed review coordination.

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Architecture | Two-phase pipeline (requesting → receiving) | Maps to superpowers requesting/receiving skills. Keeps common case fast, specialist depth opt-in. |
| Default reviewer | Single generalist, scaled by change size | One agent sees the full picture. Specialists are targeted follow-ups, not parallel sweeps. |
| Specialist model | Emergent from usage, not pre-shipped | Built-in specialists are premature. Specialists that matter to a project emerge from repeated review patterns. |
| Progress tracking | jj duplicate+squash, opt-in via `--track` | Gesoff technique automated for agents. No auto-detection threshold in v1 — explicit opt-in only. |
| Output | Local by default, GitHub via `--post` | Reviews changes, not PRs. GitHub posting is one output destination. |
| Vocabulary | Changes, not PRs | jj-native. A change is identified by a change ID. A PR is a downstream artifact. |
| Concern types | Enum-normalized | Prevents inconsistent strings across generalists. Required for reliable history aggregation and specialist dispatch. |
| Specialist storage | Project-scoped markdown files | Same format as plugin agents. Editable, versionable, promotable. |
| Review findings | Structured JSON output only (v1) | No source file annotations in v1 — avoids risk of `REVIEW(peer):` markers accidentally landing in the codebase. Findings are in the JSON response and `history.jsonl`. Annotations may be added in a future version once cleanup behavior is proven. |

## Plugin Structure

```
peer-review-jj/
├── plugin.json
├── commands/
│   └── peer-review.md              # /peer-review — single entry point
├── skills/
│   ├── requesting-change-review.md # phase 1: assess, partition, dispatch generalists
│   └── receiving-change-review.md  # phase 2: aggregate, present, handle specialist dispatch
├── agents/
│   └── change-reviewer.md          # generalist reviewer
├── scripts/
│   ├── block-raw-git.sh
│   └── block-review-markers.sh     # lint: fail if REVIEW(peer): found in committed code
└── README.md
```

Per-project (created at runtime, not in the plugin):
```
.claude/peer-review/
├── history.jsonl                    # review event log (append-only)
└── specialists/                     # project-specific specialists (emergent)
    └── <concern-type>.md            # e.g., error-handling.md
```

### `history.jsonl` Schema

Each line is a self-contained review event:

```json
{
  "timestamp": 1710523200,
  "revision": "abc12def",
  "files_reviewed": ["src/api/client.rs", "src/api/auth.rs"],
  "findings_count": {"critical": 0, "important": 2, "minor": 1},
  "concerns": [
    {
      "type": "ErrorHandling",
      "pattern": "broad exception types",
      "files": ["src/api/client.rs"],
      "line_ranges": [{"start": 45, "end": 90}]
    }
  ],
  "verdict": "with_fixes"
}
```

Append-only, no read-modify-write. The `concerns` array drives specialist emergence — count distinct `pattern` values per `type` across entries.

**Durability:** Loss of `history.jsonl` resets specialist emergence tracking but does not affect existing specialists. The specialist markdown files in `.claude/peer-review/specialists/` are the durable artifact. The history is an acceleration layer for emergence detection, not a source of truth.

## Command Flow (`/peer-review`)

### Invocation

```
/peer-review                          # review @ (default)
/peer-review <revision>               # review specific change
/peer-review --deep errors types      # generalist + specialist dispatch
/peer-review --track                  # enable progress tracking
/peer-review --post                   # post findings to GitHub PR
/peer-review --json                   # raw structured output
/peer-review --discard                # abandon review state after completion (default: keep)
```

### Flow

1. **Assess** — `jj diff --stat` on target revision, count total lines changed
2. **Decide tracking** — if `--track`: set up duplicate+squash (see Progress Tracking)
3. **Decide generalist count** — 1 per ~300 lines of changes, minimum 1
4. **Partition files** — split changed files across generalists using these rules in priority order:
   - A single file exceeding 300 lines of changes gets its own generalist
   - Directory affinity: files in the same directory stay together when possible
   - Line count balance: partitions should be roughly equal in total lines changed
   - When affinity and balance conflict, prefer affinity (reviewing related files together produces better findings)
5. **Invoke requesting skill** — dispatch generalists in parallel, collect structured JSON
6. **Invoke receiving skill** — aggregate findings, deduplicate across generalists, present with severity tiers
7. **Check history** — append to `.claude/peer-review/history.jsonl`, check for specialist emergence threshold
8. **Present results** — findings + verdict + specialist recommendations (if any) + specialist creation prompt (if threshold hit)

If `--deep` is specified: after step 6, auto-dispatch named specialists scoped to generalist-flagged locations. Aggregate specialist findings into final output. The `--deep` flag accepts lowercase aliases that map to enum values: `errors` → `ErrorHandling`, `types` → `TypeDesign`, `tests` → `TestCoverage`, `comments` → `CommentAccuracy`, `simplify` → `CodeSimplification`, `security` → `Security`, `perf` → `Performance`, `concurrency` → `Concurrency`.

### Output Format (local, default)

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

## Requesting Skill (`requesting-change-review`)

Handles phase 1: context packaging and generalist dispatch.

### Responsibilities

- Assess total change size via `jj log -r <rev> --no-graph -T 'self.diff().stat().total_added() ++ " " ++ self.diff().stat().total_removed()'`
- Get per-file line counts for partitioning via `jj log -r <rev> --no-graph -T 'self.diff().stat().files().map(|entry| "{ \"path\": " ++ entry.path().display().escape_json() ++ ", \"lines_added\": " ++ entry.lines_added() ++ ", \"lines_removed\": " ++ entry.lines_removed() ++ " }\n")'`
- Determine generalist count (1 per ~300 lines, min 1)
- Partition files into groups by directory affinity and line count balance
- Package context as a prompt template for each generalist
- Dispatch generalists in parallel
- Collect structured JSON responses
- If tracking enabled: manage duplicate+squash state, squash clean files as generalists complete

### Generalist Prompt Template

Each generalist receives instructions (not a JSON payload):

- **Scope**: which files are theirs and only theirs
- **How to read**: `jj diff -r <rev>` scoped to their files, plus permission to read full files for surrounding context
- **Guidelines**: relevant CLAUDE.md content inline
- **Change context**: revision, description, change metadata
- **Output schema**: the response schema to produce

### Generalist Response Schema

```json
{
  "files_reviewed": ["src/foo.rs", "src/bar.rs"],
  "findings": [
    {
      "severity": "critical|important|minor",
      "confidence": 85,
      "description": "what's wrong",
      "reason": "why it matters",
      "file": "src/foo.rs",
      "line_range": {"start": 45, "end": 52},
      "guideline": "CLAUDE.md says '...'",
      "fix_hint": "optional suggestion"
    }
  ],
  "specialist_recommendations": [
    {
      "concern": "ErrorHandling",
      "files": ["src/foo.rs"],
      "line_ranges": [{"start": 45, "end": 52}],
      "rationale": "broad exception types in 2 catch blocks"
    }
  ],
  "partition_verdict": "yes|no|with_fixes",
  "verdict_reasoning": "one sentence"
}
```

### Concern Type Enum

```
ErrorHandling
TypeDesign
TestCoverage
CommentAccuracy
CodeSimplification
Security
Performance
Concurrency
Other("<description>")
```

New concern types that don't fit the enum get tagged `Other` and are candidates for enum expansion if they recur. In JSON, `Other` is represented as: `{"concern": "Other", "other_description": "description of the concern"}`.

## Receiving Skill (`receiving-change-review`)

Handles phase 2: aggregation, presentation, and follow-up actions.

### Responsibilities

- Collect generalist responses (one or more)
- Verify coverage: union of `files_reviewed` across generalists equals the full file set
- Deduplicate findings: same file + overlapping line range = candidate duplicate. The receiving skill (an LLM agent) makes the semantic judgment on whether descriptions refer to the same issue. Implementation detail, not a string-matching algorithm.
- Reconcile verdicts: any `no` → overall `no`, any `with_fixes` → overall `with_fixes`, all `yes` → `yes`. Per-partition verdicts are preserved in the output so users can see which areas are clean vs. need fixes.
- Aggregate specialist recommendations by concern type (enum-normalized)
- Check `.claude/peer-review/history.jsonl` for specialist emergence threshold
- Present results with severity tiers

### Specialist Dispatch

- If `--deep` was specified: auto-dispatch named specialists scoped to flagged locations
- If not: show recommendations as suggested next actions
- Specialists receive scoped input (specific files and line ranges), not the full diff

### Specialist Emergence Prompt

When a concern type has 3+ *distinct patterns* (not raw occurrences) across reviews:

```
[peer-review] "error-handling" flagged in 3 reviews for this project.
  Distinct patterns: broad exception types, missing error context, swallowed retries.
Create a project specialist? (y/n)
```

Three occurrences of "broad exception types" is one pattern repeated — not a specialist signal. Three different error-handling manifestations across reviews — that's emergence.

### Verification Protocol

From superpowers `receiving-code-review`:

- Don't blindly implement findings. Verify each against the codebase.
- Push back if a finding is a false positive — with technical reasoning.
- If a finding contradicts a project decision (CLAUDE.md, architectural choice), flag it rather than act on it.
- Applies whether a human or an orchestrating agent is acting on findings.

### Output Destinations

- **Local** (default): print to terminal
- **GitHub** (`--post`): format as PR comment via `gh pr comment`. Requires an open PR on the current bookmark. If no PR exists, error with: `"No open PR found for bookmark '<name>'. Create one first or omit --post."`
- **JSON** (`--json`): raw structured output for programmatic consumption

## Generalist Agent (`change-reviewer`)

The single agent that ships with v1.

### What It Reviews

- Code quality: separation of concerns, error handling, edge cases, DRY
- Architecture: design decisions, patterns, consistency with surrounding code
- Testing: are changes tested, do tests test real behavior
- Requirements: does the change match its description, scope creep
- Guidelines: CLAUDE.md compliance where applicable

### What It Does NOT Do

- Run tests, build, lint, typecheck (CI handles that)
- Review unchanged code (unless directly relevant to understanding the change)
- Flag style issues unless CLAUDE.md explicitly requires them
- Deep-dive into specialist concerns (flags them for specialists instead)

### False Positive Awareness

- Pre-existing issues
- Linter/compiler-catchable issues
- Pedantic nitpicks
- Issues on unmodified lines
- Intentional functionality changes related to the broader change
- Issues silenced by lint-ignore comments

### Confidence Calibration

- 90-100: Certain. Verified against the code, clearly a real issue.
- 80-89: High confidence. Very likely real, checked the surrounding context.
- 50-79: Moderate. Might be real but could be intentional or context-dependent.
- Below 50: Don't report. If not at least moderate, it's noise.

Only findings with confidence >= 80 are included in the response. This matches the proven threshold from the deprecated `code-review-jj`. Can be lowered to 70 later if the receiving skill's aggregation proves capable of filtering the extra signal.

### Specialist Recommendation Trigger

When the generalist encounters something outside its depth — complex type invariants, subtle concurrency issues, error handling chains across multiple files — it adds a `specialist_recommendation` with:
- Concern type (from the enum)
- Specific file and line locations
- Rationale for why deeper analysis is warranted

It does not attempt the deep analysis itself.

### File Modification Discipline

The generalist must not modify source files during review. No annotations, no debug logging, no exploratory edits, no formatting changes. Review is a read-only operation — findings go into the structured JSON response, not the code.

## Progress Tracking (duplicate+squash)

Enabled via `--track` flag. No auto-detection threshold in v1.

### Setup

```bash
# 1. Duplicate the target change (does NOT move working copy)
#    Output format: "Duplicated <hash> as <short-change-id> <hash>"
#    Capture the change ID directly from stdout to avoid revset ambiguity
#    (a prior abandoned review could produce a false match with query-after-the-fact)
DUPLICATE=$(jj duplicate <revision> 2>&1 | sed -n 's/.*as \([a-z]*\) .*/\1/p')

# 2. Move working copy to the duplicate
jj edit $DUPLICATE

# 4. Insert an empty parent before the duplicate
#    jj new --insert-before creates a parent of @, so graph becomes:
#    target -> $REVIEWED_PARENT -> duplicate (@)
jj new --no-edit --insert-before @

# 5. Identify the new parent (it's now @-)
REVIEWED_PARENT=$(jj log -r '@-' --no-graph -T 'self.change_id().short(8)')

# 6. Tag the empty parent for detection
jj describe -r $REVIEWED_PARENT -m "review: <change-id>"
```

**Note:** jj mutation commands (`duplicate`, `new`) output human-readable text, not structured JSON. The setup uses `jj log -T` after each mutation to reliably capture change IDs. All query commands throughout the plugin use `-T` with JSON templates for agent-parseable output.

**Graph state after setup:**
```
trunk ── ... ── <target revision>
                     │
                     └── $REVIEWED_PARENT (empty, "review: <change-id>")
                          │
                          └── (duplicate, now @)
```

`jj squash` from `@` squashes into the parent (`$REVIEWED_PARENT`) by default — reviewed-clean files move up into the parent, shrinking the working copy diff.

The structured description `review: <change-id>` on `$REVIEWED_PARENT` is the detection key. Stable across rebases, unambiguous when multiple reviews are in flight.

### Two File States

| State | Location | Meaning |
|---|---|---|
| Squashed into parent | Reviewed parent commit | Reviewed (clean or with findings recorded in JSON) |
| In working copy, untouched | Working copy | Not yet reviewed |

`jj diff --stat` shows remaining unreviewed files. Findings (including for files marked as reviewed) live in the structured JSON output and `history.jsonl` — never in source files.

**No source file annotations in v1.** Findings reference files and line ranges in the JSON response. The generalist must not modify source files during review. This avoids the risk of `REVIEW(peer):` markers accidentally landing in the codebase via a careless squash or commit. Annotations may be added in a future version once cleanup behavior is proven in practice.

### Resumability

Next `/peer-review --track` invocation searches for a change with description matching `review: <target-change-id>`. If found, checks which files are already squashed (reviewed). Dispatches generalists only for files still in the working copy (not yet reviewed).

### Cleanup

Default is `--keep`. Review state persists. Auto-abandoned on next invocation if the target change ID has been merged to trunk. Detection: `jj log -r '<change-id> & trunk()' --no-graph -T '"merged"'` returns `"merged"` if the change is an ancestor of trunk. If merged, the review commits are abandoned — the review is irrelevant once the change lands. Use `--discard` to explicitly abandon review state before the change merges.

### Interaction with `--deep`

When `--track` and `--deep` are combined, specialists run after generalists have already squashed reviewed files into the parent. Specialists receive the generalist's flagged locations (file + line range from the JSON findings), not the tracking state. If a specialist finds issues in a file already squashed, its findings are reported in the output but the tracking state is not modified — the file stays squashed. Specialist findings are an additive layer on top of the generalist's assessment.

### Future: Iterative Review

pzmarzly's `jj restore --from=<bookmark>` variant handles updates mid-review. The reviewed parent holds what's been signed off, `restore` pulls in the latest version without merge conflicts. Worth pursuing for iterative review cycles after v1.

## Specialist Lifecycle

### Stage 1: Born from Repetition

The receiving skill appends to `.claude/peer-review/history.jsonl` after each review. When a concern type has 3+ *distinct patterns* across reviews, the user is prompted to create a project specialist.

Three occurrences of the same pattern is repetition, not emergence. Three different manifestations of a concern type is emergence.

### Stage 2: Scaffolded

If approved, a specialist agent is created at `.claude/peer-review/specialists/<concern-type>.md` seeded with:
- Accumulated distinct patterns from history (specific file references, descriptions)
- Relevant CLAUDE.md guidelines
- A prompt template modeled on the generalist but scoped to the concern type

### Stage 3: Enhanced

Generalists can *propose* refinements to specialists but cannot edit the active prompt. Proposals are appended to a `## Proposed Refinements` section in the specialist markdown:

```markdown
## Proposed Refinements
- [2026-03-16] change-reviewer flagged: "consider checking for panic-in-drop
  patterns in unsafe Rust code" (seen in src/cleanup.rs:45-60)
```

Only humans promote proposals into the active prompt. This prevents silent drift while preserving the recursive improvement loop.

### Stage 4: Promoted

```
project-specific:  .claude/peer-review/specialists/<concern>.md
user-global:       ~/.claude/peer-review/specialists/<concern>.md
plugin built-in:   peer-review-jj/agents/<concern>.md  (via PR)
```

Promotion is manual. Copy from project to user-global for cross-project use. PR to the plugin when universally useful.

### Discovery Order

When dispatching a specialist:
1. Project specialists (`.claude/peer-review/specialists/`)
2. User-global specialists (`~/.claude/peer-review/specialists/`)
3. Plugin built-in agents (`peer-review-jj/agents/`)

First match for the concern type wins. Project-specific fully shadows user-global and built-in — no merge, no inheritance, no layering.

### Specialist Memory

When dispatching a specialist, the receiving skill extracts that specialist's prior findings from `history.jsonl` and includes a summary:

> "Patterns previously observed in this project (for context, not as a checklist): broad exception types (3x, last seen 2026-02-10), missing error context in retry paths (2x, last seen 2026-03-01)."

Framed as context, not a checklist — prevents confirmation bias. Recency timestamps let the specialist calibrate whether patterns are still active or historical (addressed in a prior sweep = hunting for ghosts).

## Deprecation

`peer-review-jj` replaces three existing plugins:

| Plugin | Status | Migration |
|---|---|---|
| `code-review-jj` | Removed | GitHub posting → `--post` flag. Confidence scoring → generalist calibration. False positive list → generalist prompt. |
| `pr-review-toolkit-jj` | Removed | 6 specialist agents → reference material for generalist prompt and specialist scaffolding. Aspect filtering → specialist recommendations. |
| `feature-dev-jj` | Removed | Unused. Superpowers brainstorming skill covers the workflow. |

### What Migrates

- False positive awareness list → generalist prompt
- Confidence scoring approach → generalist confidence calibration
- GitHub comment formatting → `--post` output path
- `block-raw-git.sh` hook → carried over as-is
- New `block-review-markers.sh` hook — safety backstop that greps for `REVIEW(peer):` in code being committed/pushed and fails if found. Guards against future annotation features leaking markers into the codebase.
- Agent specialized knowledge → reference for specialist scaffolding template

### What Doesn't Migrate

- The 5-agent parallel dispatch model (replaced by scaled generalists)
- The aspect filtering UX (replaced by specialist recommendations)
- PR-centric vocabulary (changes, not PRs)

## jjp Integration Path (Future)

How `peer-review-jj` evolves once jjp exists.

### What Changes

| Concern | v1 (no jjp) | With jjp |
|---|---|---|
| Review setup + progress | `jj duplicate` + `jj squash`, `review: <change-id>` description matching | `jjp review <revision>` — idempotent, manages setup and resumption |
| Multi-reviewer coordination | None — single reviewer at a time | `jjp review status` shows all reviewers, prevents duplicate effort via CRDT |
| Specialist memory + lifecycle | `.claude/peer-review/history.jsonl` | Same — stays as-is, orthogonal to review coordination |
| Review findings | Structured JSON output + `history.jsonl` | Same — CRDT tracks coordination metadata, findings stay in JSON |

### What Stays the Same

- The command surface (`/peer-review`)
- The two-phase flow (requesting → receiving)
- The generalist-first, specialist-on-demand model
- The specialist lifecycle (emergence, refinement, promotion)
- The output format and severity tiers
- `.claude/peer-review/` for specialist personas and history

### Cross-Kind Awareness

A reviewer is reviewing `src/auth.rs`. An editor in another workspace has an active `jjp intent` on the same file. The reviewer sees this overlap (Intent + Review on same region = informational, per jjp design) and defers findings on that file — the code is about to change, so reviewing it now is wasted effort.

### Resumability Simplification

With jjp, the plugin drops its own detection heuristic. `jjp review <revision>` is idempotent — re-running reuses existing setup. The requesting skill just calls it and gets back either fresh or existing state. No description matching, no graph inspection.

### Integration Trigger

The requesting skill checks for `jjp` on PATH. If available, uses `jjp review` commands. If not, falls back to v1 mechanics. Presence detection, no configuration.
