# Permission Gateway + Fan-Flames Design Spec

**Date:** 2026-03-18
**Status:** Ready
**Build order:** Permission Gateway first, Fan-Flames second

---

## Overview

Two new capabilities for autonomous subagent workflows in jj repositories:

1. **`permission-gateway`** — Standalone plugin. A tiered PreToolUse hook that auto-approves safe commands, blocks dangerous ones, and escalates ambiguous cases to an LLM. Reduces human approval bottleneck for subagent-heavy workflows.

2. **`workspace-jj:fan-flames`** — New skill in the existing `workspace-jj` plugin. Orchestrates parallel subagent execution across isolated jj workspaces, then reunifies results into a single change. Delegates dispatch to superpowers skills, handles jj-specific lifecycle.

```
┌──────────────────────┐     ┌──────────────────────────────┐
│  permission-gateway   │     │  workspace-jj (enhanced)      │
│  (new plugin)         │     │                                │
│                       │     │  ┌──────────────────────────┐  │
│  PreToolUse hook      │     │  │ 🪭🔥 fan-flames skill    │  │
│  ┌─────────────────┐  │     │  │                          │  │
│  │ Tier 1: Rules   │  │     │  │ • Creates N workspaces   │  │
│  │ (fast, regex)   │  │     │  │ • Dispatches agents      │  │
│  │                 │  │     │  │   (via superpowers)       │  │
│  │ Tier 2: Prompt  │  │     │  │ • Reunifies changes      │  │
│  │ (LLM, edge)    │  │     │  │   (jj squash --from)     │  │
│  └─────────────────┘  │     │  │ • Calls /peer-review     │  │
│                       │     │  └──────────────────────────┘  │
│  Used by any plugin   │     │                                │
│  or subagent workflow  │     │  Uses: permission-gateway      │
└──────────────────────┘     │  Delegates: superpowers         │
                              └──────────────────────────────────┘
```

---

## Part 1: Permission Gateway

### Purpose

Remove the human approval bottleneck for subagent workflows. When 3 agents are running in parallel, each making dozens of tool calls, prompting the human for every `npm test` or `jj diff` destroys the parallelism benefit.

### Plugin Structure

```
plugins/permission-gateway/
├── .claude-plugin/
│   └── plugin.json
├── scripts/
│   └── permission-gate.sh          # Tier 1: deterministic rules
├── prompts/
│   └── permission-evaluate.md      # Tier 2: prompt hook template
└── README.md
```

### Tiered Evaluation

**Tier 1 — Deterministic rules** (~0ms, runs first):

Fast regex matching against known-safe and known-dangerous patterns.

| Category | Examples | Decision |
|----------|---------|----------|
| Safe reads | `ls`, `cat`, `head`, `tail`, `wc`, `jq`, `echo`, `pwd` | approve |
| Safe dev tools | `npm test`, `npm run {test,lint,build,dev,start}`, `cargo test`, `pytest`, `make`, `tsc` | approve |
| Safe VCS | `jj log`, `jj status`, `jj diff`, `jj show` | approve |
| Destructive FS | `rm -rf /`, `chmod -R 777`, `> /etc/*` | deny |
| Privilege escalation | `sudo *`, `su -`, `doas` | deny |
| Dangerous VCS | `git push --force`, `git reset --hard`, `jj git push --force` | deny |
| Network exfil | `curl * \| sh`, `wget * && bash` | deny |

Everything not matched falls through to Tier 2.

**Tier 2 — Prompt hook** (~5-15s, only for ambiguous commands):

Native Claude Code prompt hook. The LLM evaluates the command considering:
- Is this command destructive or reversible?
- Does it affect shared state (push, deploy, publish)?
- Does it match the apparent task context?
- Could it exfiltrate data or credentials?

Returns `approve`, `deny`, or `ask` (escalate to human).

### Configuration Layers

Three levels, most specific wins (project > user global > plugin defaults):

| Level | Location | Purpose |
|-------|----------|---------|
| Plugin defaults | Hardcoded in `permission-gate.sh` | Baseline safe/dangerous rules |
| User global | `~/.claude/permission-gateway.local.md` | Personal preferences across all projects |
| Project | `<project>/.claude/permission-gateway.local.md` | Project-specific rules |

**`.local.md` format:**

```yaml
---
rules:
  approve:
    - "terraform plan"
    - "docker compose up"
    - "kubectl get *"
  deny:
    - "terraform apply"
    - "kubectl delete"
  ask:
    - "docker push"
---

## Notes
Terraform apply requires manual approval — we've had
incidents with auto-approved infra changes.
```

YAML frontmatter for machine-parseable rules. Markdown body for human context and for Claude to understand the *why* behind rules.

### Hook Registration (plugin.json)

Single command hook that handles both tiers internally. This avoids the parallel execution problem — if Tier 1 and Tier 2 were separate hooks, Claude Code would run them simultaneously, meaning the LLM evaluates every command even when Tier 1 already has a definitive answer.

```json
{
  "name": "permission-gateway",
  "description": "Tiered permission gateway — auto-approves safe commands, blocks dangerous ones, LLM-evaluates edge cases",
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/permission-gate.sh"
          }
        ]
      }
    ]
  }
}
```

**Architecture decision:** `permission-gate.sh` handles both tiers sequentially:
1. Tier 1: regex match against rules (hardcoded + `.local.md`) → if matched, return immediately
2. Tier 2: if no Tier 1 match, output a prompt-style evaluation request for the LLM via the hook's `systemMessage` field, or fall through to `ask` (escalate to human)

This keeps Tier 2 as a fallback, not a parallel path.

### .local.md Parsing

The `permission-gate.sh` script parses YAML frontmatter from `.local.md` files using `sed` to extract the frontmatter block and `grep`/`awk` for simple key-value extraction. No `yq` dependency required — the rule format is flat enough for line-oriented parsing:

```bash
# Extract rules between --- markers
# Each rule line is "    - \"pattern\"" under approve/deny/ask sections
# Parse into shell arrays for regex matching
```

### Rule Precedence (One-Way Ratchet)

Evaluation order: **Hardcoded Deny → .local.md → Hardcoded Confirm → Hardcoded Approve → Tier 2 LLM**

The deny tier is an **immutable floor**. Hardcoded deny patterns run *before* `.local.md` rules, so no override can loosen a deny to confirm or approve. This prevents a prompt injection attack where a malicious file instructs Claude to write a `.local.md` rule promoting a denied command.

- `.local.md` CAN: add new deny/confirm/approve rules for commands not already hardcoded-denied
- `.local.md` CANNOT: override a hardcoded deny to confirm or approve
- Within `.local.md`: project > user global; deny wins ties at same level

### Gate the Gate

Writes to files matching `permission-gateway` in the path trigger a human confirmation prompt (via Write/Edit PreToolUse hooks). This catches the attack vector where prompt injection instructs Claude to silently modify `.local.md` rules before the ratchet even applies.

### Decision Logging

Every decision (APPROVE, DENY, CONFIRM) is logged with timestamp and command to `.claude/permission-gateway.log`. This enables:
- Rule self-tuning: frequently-confirmed commands get promoted to `.local.md` approve rules
- Audit trail: review what was blocked, approved, or confirmed
- Anomaly detection: spot auto-approved commands that shouldn't be (typos in safe-rm paths, etc.)

### Future: `permission-gateway tune` Command (Phase 3)

Scan the log and propose `.local.md` additions based on confirmation frequency:

```
Suggested promotions (confirmed >10x, never denied):
  pip install     (42 confirms, 0 denies) → approve?
  htop            (12 confirms, 0 denies) → approve?
  terraform plan   (8 confirms, 0 denies) → approve?
Write to .local.md? [y/n]
```

The log format already supports this — timestamp, decision, and command are all that's needed.

### Graceful Degradation

If permission-gateway is not installed, subagent workflows still function — the human just gets more permission prompts. No plugin should hard-depend on permission-gateway.

---

## Part 2: Fan-Flames (workspace-jj)

### Purpose

Orchestrate parallel subagent execution across isolated jj workspaces, then reunify results into a single change. The jj-native equivalent of running multiple developers on separate branches and merging.

### Skill Location

```
plugins/workspace-jj/
├── skills/
│   └── fan-flames.md    # new skill
```

### Lifecycle

```
1. PLAN         User provides task descriptions (or references a plan doc)
                Skill validates tasks are independent by checking
                file paths in the plan — tasks touching the same files
                are flagged for the user to confirm or restructure

2. FAN OUT 🪭   For each task:
                ├── Claude Code's WorktreeCreate hook fires
                │   → workspace-jj creates jj workspace at
                │     .claude/workspaces/<task-name> named workspace-<task-name>
                ├── Dispatch subagent with isolation: "worktree"
                └── Subagent works autonomously
                    (permission-gateway active underneath)

3. COLLECT      Wait for all subagents to return
                Classify: succeeded / failed / partial

4. FAN IN 🔥    Order workspaces by files touched (ascending) unless
                --merge-order is specified explicitly.
                For each completed workspace:
                ├── jj squash --from workspace-<task-name>@ --into @
                │   (workspace-<name>@ is jj's revset for a workspace's
                │    working-copy commit; @ refers to the default
                │    workspace where the orchestrator runs)
                ├── Handle conflicts (jj marks them, not blocking)
                └── jj workspace forget workspace-<task-name>

5. VERIFY       Run /peer-review on the combined result
                Compare merged result against original plan
                Report coverage: which plan requirements landed
```

**Note on workspace naming:** The `jj-workspace-create.sh` script prefixes jj workspace names with `workspace-`. Fan-flames uses this convention. The revset `workspace-<name>@` targets that workspace's working-copy commit. The directory path uses `.claude/workspaces/` — "worktree" only appears in Claude Code's hook API names (`WorktreeCreate`/`WorktreeRemove`), which we can't change.

### Superpowers Integration

Two integration points:

**A) CLAUDE.md override table entry:**

```markdown
| subagent-driven-development | workspace-jj:fan-flames | jj-native workspace isolation with reunification |
```

When `subagent-driven-development` detects a jj repo, it routes through fan-flames automatically.

**B) Skill description triggers:**

The fan-flames skill description matches intents like:
- "fan out these tasks into parallel workspaces"
- "run these tasks in parallel with isolation"
- "dispatch subagents for these independent tasks"

### Dispatch Delegation

Fan-flames does NOT reimplement agent dispatch. It delegates to superpowers skills (these are built-in Claude Code superpowers skills, not plugins in this repo):

- For **plan-based execution** → references `superpowers:subagent-driven-development` dispatch patterns (fresh subagent per task, two-stage review gates)
- For **ad-hoc parallel tasks** → references `superpowers:dispatching-parallel-agents` patterns (concurrent independent investigations)

Fan-flames only handles the jj-specific bookends:
- Workspace creation (before dispatch)
- Change reunification (after dispatch)
- Plan coverage reporting (after merge)

### Ad-hoc Mode (no plan document)

Fan-flames supports both plan-based and ad-hoc task lists. When no plan document is referenced:
- User provides a list of independent task descriptions
- Plan coverage reporting becomes task completion reporting (N/M tasks succeeded)
- No requirement-level tracking, just task-level pass/fail

### Parallelism Limits

Fan-flames does not impose a hard cap on concurrent workspaces. Practical limits come from:
- Claude Code's own subagent concurrency limits
- Machine resources (each workspace is lightweight — jj shares the store)
- User's plan complexity

Recommendation in the skill: 3-5 concurrent workspaces for most tasks.

### Failure Handling

Partial success is preserved. If 2 of 3 subagents succeed:

```
🪭🔥 Fan-flames complete (2/3 tasks)

### Merged
- 🔥 Task 1: "Add validation middleware" — squashed into @
- 🔥 Task 3: "Update API types" — squashed into @

### Failed
- Task 2: "Migrate auth store" — test failures in auth_test.rs
  Workspace: task-2 (preserved, inspect with /workspace-list)

### Plan Coverage
- 4/6 plan requirements satisfied by merged tasks
- 2 requirements blocked by Task 2
```

Failed workspaces are **preserved** (not cleaned up) so the user can:
- Inspect with `/workspace-list`
- Fix manually
- Re-dispatch a single subagent to that workspace

### Conflict Handling

jj's conflict model is first-class — conflicts are recorded in the tree, not blocking. When squashing from multiple workspaces:

1. Squash workspaces one at a time (order by least likely to conflict)
2. If jj reports conflicts after a squash, report them clearly
3. User decides: resolve now, skip this workspace, or abandon

### Prerequisites

- `workspace-jj` must be set up (`/workspace-setup` already run)
- Plan document or explicit task list provided by user
- `permission-gateway` recommended but not required

---

## End-to-End Flow

```
User: "Execute this plan, use subagents"
           │
           ▼
  superpowers:subagent-driven-development
  detects jj repo → CLAUDE.md routes to
           │
           ▼
  workspace-jj:fan-flames
           │
     ┌─────┼─────┐
     ▼     ▼     ▼
   WS-1  WS-2  WS-3     ← jj workspace add (each)
   Agent Agent Agent     ← dispatched with isolation:"worktree"
     │     │     │
     │     │     │       ← permission-gateway hook active in each
     │     │     │         Tier 1: auto-approves safe commands
     │     │     │         Tier 2: LLM evaluates edge cases
     │     │     │
     ▼     ▼     ▼
   Done  Fail  Done
     │     │     │
     ▼     ▼     ▼
  Fan-in phase:
   ├── Squash WS-1 into @         ✓
   ├── Skip WS-2 (preserved)      ✗ report vs plan
   ├── Squash WS-3 into @         ✓
   └── /peer-review on combined result
```

---

## Build Order

**Phase 1: Permission Gateway** (standalone, immediately useful)
- Plugin scaffold
- Tier 1 deterministic rules + .local.md parsing
- Tier 2 prompt hook
- Testing: verify approve/deny/ask across rule tiers

**Phase 2: Fan-Flames** (depends on workspace-jj, enhanced by permission-gateway)
- Skill file with lifecycle orchestration
- jj squash --from integration
- Plan coverage reporting
- Failure handling and workspace preservation
- CLAUDE.md override entry for superpowers integration
- Testing: multi-workspace dispatch and reunification

---

## Resolved Questions

1. **Tier 1 + Tier 2 hook coordination** — Single command hook handles both tiers sequentially. Tier 1 returns immediately on match; Tier 2 only fires as fallback.

2. **Fan-flames without a plan** — Yes, supports ad-hoc task lists. Plan coverage becomes task completion reporting (N/M succeeded).

3. **Workspace merge order** — Smallest diff first, automatically. Measured by **files touched** (not lines changed) — files touched is a better proxy for conflict surface area. A 500-line change to one isolated file is safer to merge early than a 20-line change touching 8 files across 4 modules. Smallest-first establishes a stable base early; each subsequent squash resolves against maximum already-merged context rather than compounding conflicts.

   Escape hatch for when the user knows something the tool doesn't:
   ```
   # Default: automatic (smallest diff first by files touched)
   fan-flames --merge-order auto
   # Override: explicit ordering
   fan-flames --merge-order task-3,task-1,task-2
   ```

4. **Subagent model selection** — Defer to the session model. Reasons:
   - **Security-sensitive decision.** Permission evaluation shouldn't optimize speed over judgment. A weaker model might approve something ambiguous the session model would catch. Cost of false approve >> cost of 10 extra seconds.
   - **Tier 2 is rare.** With well-tuned Tier 1 rules, Tier 2 fires for ~5-10% of commands. Optimizing the rare path for speed is the wrong tradeoff.
   - **Simplicity.** Model selection introduces configuration, API key routing, and fallback handling — unnecessary complexity for invisible infrastructure.

   If Tier 2 latency becomes a problem, the right fix is improving Tier 1 coverage: repeated Tier 2 approvals should become Tier 1 rules in `.local.md`. Permission-gateway can suggest rule additions after a session based on what Tier 2 kept approving — a natural feedback loop.
