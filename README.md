# Claude Code Plugins for jj (Jujutsu)

Claude Code plugins for **jj (Jujutsu)** workflows — project setup, workspace isolation, commit management, peer review, and a hard wall against raw `git`.

## Who this is for

These plugins are for people who have chosen **jj (Jujutsu)** and want their coding agents to *stay* on it. They are opinionated and jj-only by design: the jj plugins install **hard walls**, not gentle reminders. If you're git-first, or want something neutral between the two, this isn't it.

## Why hard walls instead of instructions

LLM agents have a strong reflex toward git. It dominates their training data, so `git add` / `git commit` / `git status` are what they reach for automatically — often mid-task, **even when the project explicitly specifies jj, and even when the agent agrees jj is the better choice.** A written rule like "use jj, not git" is a suggestion the model can rationalize past a moment later.

So enforcement sits below the level the model can argue with. A `PreToolUse` hook (`block-raw-git.sh`) registered by `project-setup-jj` and `peer-review-jj` intercepts every Bash call, blocks raw `git`, and hands back the jj equivalent — turning a reflexive `git commit` into a redirect the agent recovers from. The two deliberate exceptions are `jj git` subcommands (e.g. `jj git push`) and the `gh` CLI, the legitimate git-interop seams.

All jj output commands (`jj log`, `jj diff`, `jj bookmark list`, `jj op log`, `jj workspace list`, `jj show`, `jj evolog`, `jj op show`, `jj config list`, `jj tag list`) use JSON templates (`-T 'json(self)'`) by default, giving Claude Code structured, machine-parseable output instead of human-readable text. Requires jj >= 0.31.0.

## Plugins

| Plugin | Description | Commands | Agents |
|--------|-------------|:--------:|:------:|
| **project-setup-jj** | Bootstrap jj workflow enforcement with `/project-setup` | 1 | — |
| **workspace-jj** | Worktree isolation for jj repos via `jj workspace` hooks | 2 | — |
| **commit-commands-jj** | jj commit workflows — commit, push, PR creation, and more | 16 | — |
| **peer-review-jj** | Unified change review — generalist-first with emergent specialists | 1 | 1 |

## project-setup-jj

Bootstrap jj workflow enforcement for any project with a single command. Sets up a SessionStart hook (shows jj context each session), a PreToolUse guard hook (prompts `jj new` before editing non-empty changes), permissions (allow jj/gh, deny git), and a CLAUDE.md policy directive.

**Setup:**

```bash
# 1. Install from plugin manager
/plugin install project-setup-jj@muloka-claude-plugins

# 2. Run setup in your jj project
/project-setup

# 3. Restart Claude Code for SessionStart hook
```

**Requires:** [jj](https://martinvonz.github.io/jj/) and [jq](https://jqlang.github.io/jq/)

## workspace-jj

Enables Claude Code's `--worktree` flag and subagent `isolation: "worktree"` in jj repositories. Claude Code uses git worktrees by default for isolated parallel sessions — this plugin replaces that with jj workspaces via `WorktreeCreate` and `WorktreeRemove` hooks, so `--worktree` works natively in jj repos.

**Setup:**

```bash
# 1. Install from plugin manager
/plugin install workspace-jj@muloka-claude-plugins

# 2. Run setup in your jj project (copies hook scripts, configures settings)
/project-setup

# 3. Restart Claude Code, then use worktrees
claude --worktree feature-auth
```

Claude Code doesn't pick up `WorktreeCreate`/`WorktreeRemove` hooks from plugins — they must be in project settings. `/project-setup` (from `project-setup-jj`) handles this: its installer copies the hook handlers to `.claude/hooks/` and registers them in `.claude/settings.local.json`. There is no separate `/workspace-setup` command — it was folded into `/project-setup` so one command installs every jj hook.

**Requires:** [jj](https://martinvonz.github.io/jj/) and [jq](https://jqlang.github.io/jq/)

## commit-commands-jj

Streamline your jj commit workflow with simple slash commands.

**Commands:** `/commit`, `/commit-push-pr`, `/new`, `/edit`, `/describe`, `/squash`, `/abandon`, `/sync`, `/undo`, `/finish`, `/clean_stale`, `/show`, `/evolog`, `/op-show`, `/tag-list`

## peer-review-jj

Unified change review for jj repos. Two-phase pipeline (requesting → receiving) with generalist-first architecture and emergent specialists.

**Command:** `/peer-review`

```
/peer-review                          # review current change (@)
/peer-review <revision>               # review specific change
/peer-review --deep errors types      # generalist + specialist dispatch
/peer-review --track                  # enable progress tracking (duplicate+squash)
/peer-review --post                   # post findings to GitHub PR
/peer-review --json                   # raw structured output
```

**Agent:** `change-reviewer` — generalist reviewer that scales with change size (1 per ~300 lines). Returns structured JSON findings with severity tiers and confidence scoring (>= 80 threshold). Recommends specialists for deeper analysis when needed.

**Specialist emergence:** After 3+ reviews flag distinct patterns for a concern type, the plugin prompts to create a project-specific specialist at `.claude/peer-review/specialists/`.

Replaces the deprecated `code-review-jj`, `pr-review-toolkit-jj`, and `feature-dev-jj` plugins. See [design doc](docs/peer-review-jj/2026-03-16-peer-review-jj-design.md) for full details.

## Installation

Add the marketplace and install plugins via the plugin manager:

```
/plugin marketplace add muloka/claude-plugins
/plugin install peer-review-jj@muloka-claude-plugins
```

Or browse available plugins:

```
/plugin
```

**Note:** After installing workspace-jj, run `/project-setup` in your jj project and restart Claude Code — that is what installs the `WorktreeCreate`/`WorktreeRemove` hooks into project settings.

## Evals

Two verification layers cover this repo, doing different jobs:

| Layer | Question it answers | Where | Gating |
|---|---|---|---|
| 1 — evals | Does a plugin change what the **model** does? | `plugins/<name>/evals/<case>/` | none — run by hand |
| 2 — shell tests | Do the **scripts** behave? | `plugins/<name>/tests/test-*.sh`, `.github/tests/` | CI, every push |

Layer 2 is the gate. The eval suite gates nothing — it is a measurement instrument, run deliberately, to answer what a deterministic test cannot: whether the prose and hooks a plugin ships actually move model behaviour. Each case runs under `--ablation with-without` (plugin loaded vs. not), and the **delta between the two arms is the result**. A case whose arms score the same measured nothing, however green it looks.

### Running it

```bash
# free — list the cases that would run, and print the CLI invocation
/bin/bash .github/scripts/run-evals.sh --discover-only
/bin/bash .github/scripts/run-evals.sh --plugin commit-commands-jj --dry-run

# paid — actually run them (spends model tokens; see below)
/bin/bash .github/scripts/run-evals.sh --plugin commit-commands-jj --runs 2
```

Run from the repo root — running elsewhere exits 3 rather than dying on a stray `find` error. Useful flags: `--case <glob>` scopes to one case, matched against the case's `name:` field exactly as the CLI matches it (a case that declares no name defaults to its directory basename); `--gate report` downgrades `NO_GAP`/`PARTIAL` from failures to findings; `--max-cost-usd` caps spend (default `5`); `--keep-temp` keeps the sandboxes. `--allow-tools` accepts a comma- or space-separated list and forwards each tool separately. A `--plugin`/`--case` combination that selects no case exits 3: scoped-to-nothing is not a clean run. Verdict rows go to stdout as TSV; everything else, including the result-JSON path, goes to stderr.

### Manual by design — not wired into CI

Three independent reasons, any one of which is sufficient:

- **Early access.** `claude plugin eval` sits behind `CLAUDE_CODE_WALNUT_SPIRE=1`, which the runner sets on every invocation. That requirement was measured on CLI **2.1.216**; by **2.1.220**, `plugin eval --help` exits 0 with the variable unset. Setting it stays harmless either way, so the runner keeps doing so — but **no logic may treat "exits 1 without the variable" as gate detection.** That signal has already drifted once.
- **Model spend.** Every run costs real money — per case, per arm, per run. Tranche 1 cost $3.77 in total. A per-push CI job would bill this repo for every typo fix.
- **No entitlement guarantee on runners.** Nothing guarantees a CI runner can obtain the same early-access entitlement the local operator has, and the suites are macOS/bash 3.2 to begin with.

### Verdicts

The runner emits one TSV row per case — `name / score / score_without / delta / verdict`:

| Verdict | Condition | Means |
|---|---|---|
| `DISCRIMINATING` | Δ ≥ 0.5 | the plugin measurably changes behaviour; the case earns its keep |
| `PARTIAL` | 0 < Δ < 0.5 | some effect — check attribution grader-by-grader before believing it |
| `NO_GAP` | Δ = 0 | both arms did equally well: the **case** cannot discriminate. Move the assertion to layer 2 |
| `REGRESSION` | Δ < 0 | the plugin made things worse. Fails in both gate modes |
| `BROKEN` | both arms scored 0.00 | **the harness failed, not the plugin** |

Δ comparisons carry a 1e-9 tolerance. The CLI computes the delta by subtraction, so a case scoring 7/10 with and 2/10 without arrives as `0.49999999999999994`; without the tolerance a textbook shipping case at exactly the threshold is filed `PARTIAL` and fails CI.

> **`BROKEN` never means "no gap".** Both arms scoring zero is the signature of a case that could not run at all — nearly always a **gated tool the case declares that `--allow-tools` does not grant**, leaving the agent unable to call it in either arm. Misread as "no difference between the arms", it deletes the best case in the suite. The runner also checks this before spending and exits 7 — for both case layouts, both YAML forms, and whatever `--case` actually selects. Other non-zero exits: 3 nothing measured (no cases discovered, none selected, or none returned), 4 gate failure, 5 result-schema drift, 6 budget-truncated run, 64 bad argument or bad `--gate` (rejected before spending), 65 missing or malformed result file.

### Measured results

Tranche 1 (issue #79) is written up in **[docs/eval-triage-2026-07.md](docs/eval-triage-2026-07.md)** — what shipped, what was cut and why, and three runner gaps found but left unfixed. Two cases ship today, both under `plugins/commit-commands-jj/evals/`, both at Δ +1.00, and they now exercise **different** branches of `block-raw-git.sh`. `hook-blocks-git-internals` did not: its name promised the internals branch while its `git rev-parse HEAD` prompt was answered by the raw-git branch, which returns first (§1.1). Issue #103 repointed it at a dot-git path, narrowed its grader to wording the raw-git branch cannot produce, and re-measured at Δ +1.00 — so the triage document's §1.1 finding is resolved, not still open. A third case measured Δ 0.00 and was cut; its assertions now live in `plugins/commit-commands-jj/tests/test-block-raw-git-gating.sh`, where they are deterministic and free.

Read the triage document before authoring a case. Its §3 is the prompting-and-grading recipe that was measured to work; its §2 is three separate mechanisms that make a case report green while measuring nothing.

Failure taxonomy informed by netresearch/jujutsu-workflow-skill (MIT AND CC-BY-SA-4.0); cases independently authored.

## Relationship to claude-plugins-official

This repo started as a fork of Anthropic's [claude-plugins-official](https://github.com/anthropics/claude-plugins-official) and has evolved through two phases:

**Phase 1: jj translations** — Replaced Anthropic's git-based plugins (`commit-commands`, `code-review`, `feature-dev`, `pr-review-toolkit`) with jj-native equivalents. Same capabilities, different VCS.

**Phase 2: jj-native capabilities** — Built features that leverage jj's model in ways git can't easily support. Lightweight workspaces for parallel subagent isolation (fan-flames), first-class conflicts for multi-workspace merging, automatic working-copy snapshots eliminating the commit/stage ceremony, and operation-log-based undo for safe experimentation. These aren't ports of git workflows — they're new patterns that emerge from jj's architecture.

| Category | This repo | Anthropic original |
|----------|-----------|-------------------|
| **VCS** | jj (Jujutsu) — all plugins enforce jj-only | git |
| **Commits** | `commit-commands-jj` — jj-native with revsets, bookmarks, operation log | `commit-commands` — git add/commit/push |
| **Code review** | `peer-review-jj` — generalist-first, emergent specialists, structured findings | `code-review` — single-pass review |
| **Workspace isolation** | `workspace-jj` — jj workspaces via WorktreeCreate/Remove hooks | Not provided (git worktrees are built-in) |
| **Raw-git enforcement** | `block-raw-git.sh` — `PreToolUse` wall denying `git` at any shell command position | Not provided |
| **Project setup** | `project-setup-jj` — jj workflow enforcement, statusline, SessionStart hooks | Not provided |

**Removed from original:** `code-review`, `commit-commands`, `feature-dev`, `pr-review-toolkit` — replaced by jj-native equivalents above.

**Net new (no upstream equivalent):** `workspace-jj`, `project-setup-jj`, the raw-git wall, kaisen skill.

## License

See each plugin directory for the relevant LICENSE file.
