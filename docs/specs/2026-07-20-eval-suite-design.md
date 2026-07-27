# Eval suite — design (issue #79, tranche 1)

Date: 2026-07-20 (revised 2026-07-21 after adversarial review)
Issue: #79 — "~20 user-facing commands have never been executed"
Status: design, pending plan

## Problem

Issue #79 frames the gap as: ~20 user-facing commands have only ever been
structurally validated, never behaviourally exercised. Measured defect rate on
unexercised prose in this repo is 5–9 per file (fan-flames: 9 in #68 plus one
in #76; `/finish`'s post-merge step: 4 in #69 plus a fifth in #74).

The instrument for "skill text leads the model to act wrong" is an eval —
prompt plus assertions — as distinct from a lint, which catches "skill text
asserts something wrong". This repo has lints and has no evals.

## The finding that shapes this design

`claude plugin eval` was exercised before any design work, on a faithful port
of netresearch's `describe-noninteractive` case. Against `commit-commands-jj`
it scored 1.00. Against a **null control plugin** — a bare manifest with zero
commands, skills or hooks — it also scored **1.00**.

The 2026 base model already uses `-m` and already avoids raw git unprompted.
That case measured the model, not the plugin.

This is the central risk of the whole initiative. A suite assembled by porting
the obvious cases would be green whether or not these plugins work —
reproducing #79's own disease one level up, with a passing scoreboard that
reads as evidence. A green suite that cannot fail is worse than no suite,
because it terminates the inquiry.

Independently confirmed twice: netresearch built their runner to report the
**delta** rather than the pass rate, for the same reason; and an adversarial
review of this spec reproduced both results from scratch (`hook-blocks-raw-git`
Δ +1.00; `describe-noninteractive` Δ 0.00, twice).

Therefore: **ablation is a gate, not a report.**

### The verdict taxonomy

| Δ | Verdict | Action |
|---|---|---|
| Δ ≥ +0.5 | discriminating | ships |
| 0 < Δ < +0.5 | partial | needs written judgement in `description`, or cut |
| Δ = 0 | measures the model | cut; record the scores |
| Δ < 0 | **plugin makes the model worse** | **escalate — highest-value finding available** |
| both arms 0.00 | **case is broken** | never a verdict; fix the case |
| arms overlap across runs | noisy / inconclusive | re-run at higher `runs` |

The last two rows exist because of specific failure modes found in review. A
both-arms-zero result is categorically *not* "no gap" — it is almost always a
missing `--allow-tools` grant, and treating it as a verdict would silently
delete every genuinely discriminating case in the suite.

## Verified harness mechanics

Measured on Claude Code 2.1.216, then independently re-verified in adversarial
review. Recorded in memory as `project_eval_harness_facts`.

- `claude plugin eval` and `eval init` are **early access**: they exit 1 and
  write nothing. Gate is `statsig("tengu_walnut_spire") ||
  env.CLAUDE_CODE_WALNUT_SPIRE`. `CLAUDE_CODE_WALNUT_SPIRE=1` unlocks both. No
  interactive auth needed — it runs headless here.
- Cost: **$0.06–0.28 per run**, 2–13s per run for a small case.
- Cases live at `<target>/evals/<case-name>/case.yaml`, under the **target**.
- Grader types, exact and complete: `regex`, `tool_order`, `tool_used`,
  `file_exists`, `llm`, `baseline`.
- **Plugin hooks fire inside the harness** — the `with` arm surfaces the
  `block-raw-git.sh` deny text; the `without` arm runs `git status` normally.
- **The sandbox is fully isolated.** `--keep-temp` shows a fresh `config/`,
  `cwd/`, `home/`, `out/` — no user or project `CLAUDE.md`. The ablation is
  **not** confounded by ambient config. (This was the most likely way the
  design could have been invalidated. It wasn't.)
- **`--ablation with-without` works on path targets.** It is only the *default*
  that differs (`none` for paths, `with-without` for named plugins). Passing it
  explicitly yields a full two-arm table and a machine-readable result.

### Result JSON — verified field paths

`--output-dir` writes `aggregate-result.json` (`schema_version: "1.0"`). The
fields are **flat and snake_case**:

| Path | Meaning |
|---|---|
| `.cases[].delta` | the ablation gap the verdict taxonomy keys on |
| `.cases[].score` / `.score_without` | per-arm mean score |
| `.cases[].pass_rate` / `.pass_rate_without` | per-arm pass counts (Part A) |
| `.cases[].runs[]` / `.runs_without[]` | per-run detail, incl. `trace_path` |
| `.partial` (top level) | true when `--max-cost-usd` was breached |
| `.cost_usd`, `.plugins[]` | run accounting |

Stated as a table because getting this wrong is silent and total: a jq filter
against a non-existent path yields `null`, and `null` sorts **below every
number**, so `null < 0` is true. A delta gate built on wrong paths reads null
everywhere and files every case under "plugin makes the model worse" while
appearing to work. An earlier draft of this section carried camelCase paths
(`.cases[].aggregates.delta`, `.suite.ablation`) taken from a review report;
running the query showed every one of them resolving to null. **The runner's jq
filter must be covered by a test asserting non-null deltas on a known fixture.**

### Required schema

`execution` is a required block; `prompt` lives inside it. Every grader
requires `name`. `schema_version` is mandatory.

Rather than restate the schema in prose — the first draft of this spec got
`regex.target` wrong — the plan commits a **working exemplar** at
`plugins/commit-commands-jj/evals/hook-blocks-raw-git/case.yaml` and this
document points at it. Note `regex`'s default target is `last_message`; twelve
guessed alternative values were all rejected, so `target` is not a
transcript-section name and should be left at its default absent evidence.

### Authoring traps

Each cost a failed run during de-risking or review:

1. `context.scaffold_script` is a **path to a script file**, not inline bash.
   Under `--scaffold` it errors; **without `--scaffold` it silently does not
   run at all**, which is the worse failure.
2. Scaffolds run only under `--scaffold` (off by default).
3. `execution.env` accepts **only `EVAL_*` keys**. `JJ_USER` / `JJ_EMAIL` must
   come from the operator's shell.
4. A negative `tool_used` needs **both `min: 0` and `max: 0`**; `max: 0` alone
   yields the impossible range "expected 1..0".
5. Results default to **`<target>/evals/results/`** — inside `plugins/<name>/`,
   where they trip the #84 version-bump lint. The CLI's own `--help` documents
   this as cwd-relative and is **wrong**; verified empirically.
6. **Gated tools need `--allow-tools` on the command line.** `allowed_tools` in
   `case.yaml` is necessary but not sufficient. Omitting the grant zeroes both
   arms — see the verdict taxonomy.
7. **`--threshold` gates on absolute score, not delta.** A zero-gap case scores
   `with 1.00 / without 1.00` and the harness prints **`✓`**. The tool's exit
   semantics actively oppose this design's doctrine; the runner must compute
   its own exit code from `.cases[].aggregates.delta`.

## Architecture

### Case layout

```
plugins/<name>/evals/<case-name>/
  case.yaml
  scaffold.sh        # optional; builds a temp jj repo
```

Co-location means the #84 version-bump lint already covers eval changes.

Scaffolds harden the environment per netresearch's MIT-licensed pattern: an
isolated `JJ_CONFIG` with `ui.paginate = "never"` and `editor = "true"`, so an
accidental editor invocation no-ops instead of hanging the run.

### Ablation

Use the harness's built-in `--ablation with-without`. **No null-control
generator.** The first draft specified one, premised on the false claim that
path targets cannot ablate; review disproved this. The built-in is also *more*
valid — it disables the plugin against a byte-identical environment, whereas a
generated control differs in name, description and manifest content.

### Runner

`.github/scripts/run-evals.sh`, with `.github/tests/test-run-evals.sh` beside
it. This location is not cosmetic: CI globs `find plugins .github -path
'*/tests/test-*.sh'`, so a repo-root `scripts/` would place a companion suite
under neither root — discovered by nothing, silently, and green. Repo precedent
is `.github/scripts/`; `CONVENTIONS.md` documents `scripts/` only as a *plugin*
subdirectory.

Bash 3.2-safe per the `macos-latest` CI floor: no globstar, no associative
arrays; test with `/bin/bash`, never the interactive zsh.

Fixed flags the runner owns, so nobody rediscovers the seven traps:

- `CLAUDE_CODE_WALNUT_SPIRE=1`
- `JJ_USER` / `JJ_EMAIL` when unset
- `--ablation with-without`
- `--allow-tools Bash` (plus Write/Edit as cases require)
- `--scaffold`
- `--output-dir` outside the plugin tree (this carries the result JSON; no
  separate `--json` is needed)
- **`--threshold 0`** — load-bearing. It defaults to 1.0, so the CLI exits 1 on
  any case scoring below 1.00, which under `set -e` kills the runner before the
  delta gate runs. Every case worth measuring scores below 1.00 by definition.
- `--max-cost-usd` with a default ceiling. Breach is CLI **exit 2**, which must
  be captured and passed to the gate rather than killing the script.
- `--keep-temp` exposed as a first-class flag — the only way to reach
  `trace.jsonl`, which is otherwise deleted; review had to pay to re-run a case
  purely to inspect tool sequence

Guards, each earning its place from a review finding:

- **Zero-match glob aborts.** Discovery covers **both** supported formats:
  `-path '*/evals/*/case.yaml' -o -path '*/evals/*/prompt.md'`. `eval init
  --bare` scaffolds the second one, so a single-format glob would silently skip
  cases authored the official way — #82's exact failure mode, reproduced inside
  the tool built to honour #82.
- **Tool-grant check.** If a case declares a gated tool absent from the
  `--allow-tools` grant, abort with a diagnostic rather than scoring zeros.
- **Both-arms-zero is "broken", never "no gap".**
- **Exit code computed from `.cases[].delta`**, not from `--threshold`.
- **Null-delta tripwire.** If any `.cases[].delta` reads `null`, abort — the
  result schema moved and every verdict is meaningless. Never let a null reach
  a comparison.
- **Check `.partial` before trusting deltas.** True means `--max-cost-usd` was
  breached and paid graders were skipped, leaving partial scores.

### Two-layer framing

Borrowed from netresearch:

- **Layer 1 — evals.** Does the model *behave* correctly? Non-deterministic,
  costs money, runs manually.
- **Layer 2 — shell tests.** Does the documented workflow *work* against real
  jj? Deterministic, free, gates CI. This repo has 11 such suites.

Layer 2 catches a SKILL.md citing a flag jj removed. Layer 1 catches prose that
is accurate but leads the model astray. The eval suite is the missing layer 1;
it replaces nothing. Note `commit-commands-jj` currently has **no `tests/`
directory at all** — a layer-2 gap worth filing separately.

## Tranche 1 scope

### Part A — 16-command triage sweep

**Revised after review.** The original design phrased prompts as tasks and
compared arms. Review measured that the model never invokes the commands at all
— it goes straight to Bash, with `Skill` and `SlashCommand` both called 0×. So
task-phrased prompts never read the command's prose, Δ≈0 for all 16, and the
table would report "no measurable gap" for a reason unrelated to command value:
a null result the design structurally could not have avoided.

The fix follows from what that measurement actually reveals: **slash commands
are user-invoked, not model-invoked.** "Never run" is literally true — they
execute only when the user types `/describe`. The eval must therefore simulate
*the user invoking the command*, which is not a compromise but the correct
model of how these commands are used.

So each case:

- prompts with the **literal slash-command invocation** (`/describe add the
  notes file`)
- carries a `tool_used` on `SlashCommand`/`Skill`, `min: 1`, as a **validity
  precondition** — not a scored grader
- runs at **`runs: 3`** per arm

If the precondition fails, the case reports **"did not exercise the command"** —
a distinct outcome from both "earns its keep" and "no measurable gap". Without
that distinction Part A does not ship.

Cost: 16 × 2 arms × 3 runs = 96 runs at $0.06–0.28 ≈ **$7**, ~10 minutes.
`runs: 1` was rejected on review: a single sample per arm yields a delta in
{−1, 0, +1} with no confidence attached, and the noise is asymmetric — a
spurious `without` pass reads as the actionable burden-shifting verdict. At
~$0.07/run the saving never justified the ambiguity.

Output is a triage table using the verdict taxonomy above, reporting **per-arm
pass counts** (`3/3`, `2/3`), not just means.

This is a **measurement, not a prune list**, and the framing matters. This
repo is a jj-native port of `anthropics/claude-plugins-official`'s
commit-commands; the command set exists partly to mirror upstream. Upstream
parity is itself a reason to keep a command a model could limp through without
— consistency across the two repos, and pinning behaviour that could drift, are
values the ablation number does not see. So a zero-gap command is not a
deletion candidate; the default is to keep it.

What Part A produces is therefore a **map of where the prose earns its cost**:
which commands measurably shape behaviour (and so most reward careful tranche-2
cases), which are thin wrappers the model handles unaided, and which the suite
could not exercise at all. It informs where to invest test effort, not what to
remove. No command is proposed for deletion.

### Part B — four hook and invariant cases

Targeting behaviour the model demonstrably cannot infer, guarding invariants no
lint covers.

1. **`hook-blocks-raw-git`** — built and proven, Δ +1.00, twice, by two
   independent parties.
2. **`hook-blocks-git-internals`** — the second, separately-coded branch
   (`.git/`, `git rev-parse`, `git config`).
3. **#45 pass-through — moved to layer 2, not an eval.** The invariant (outside
   a jj repo, git must be allowed) cannot be an eval: the grader asserts the
   *absence* of a deny, but the `without` arm has no hook either, so both arms
   pass and Δ = 0 regardless of whether the hook works. The case is
   structurally incapable of distinguishing "correctly passed through" from
   "no hook at all". It ships as `tests/test-block-raw-git-gating.sh` instead —
   the hook is a pure stdin/stdout function and needs no model to test.
4. **`hook-allows-jj-git-and-gh`** — `jj git push` and `gh pr view` must survive
   the negative-lookahead in the raw-git regex.

Cases 2–4 are hypotheses until ablation scores them. Non-discriminating ones are
cut and the cut recorded.

### Assertion strategy

Prefer behavioural graders over rhetorical ones. netresearch's runner disables
tools (`--tools ""`), so all 15 of their cases grade what the agent *says*. Our
`tool_used` and `tool_order` graders assert what it *did* — the main reason
their format is not worth porting directly.

For the jj non-interactive class: `tool_used` on `Bash` with `input_match`,
paired with a negative assertion at `min: 0, max: 0`.

## Prior art

netresearch/jujutsu-workflow-skill contributed the failure taxonomy: seven
classes, of which the ones mapping onto code the base model cannot infer are
colocated-repo desync (our hook's target), the ordered handoff gate (`/finish`),
workspace isolation (kaisen), and jj not reading git config. Their classes A
(interactivity deadlock) and B (git muscle memory) are most of their suite and
are what our ablation gate is most likely to kill.

**Licensing constraint for case authors: write our own prompt text.** The
taxonomy is fact about jj's CLI and carries no obligation, but their prompt
strings and assertion descriptions are CC-BY-SA-4.0; copying them verbatim would
make an Adapted Work and pull ShareAlike onto this Apache-2.0 repo. Their shell
harness patterns are MIT and safe to borrow with the notice.

## CI

Evals do **not** gate CI. They need an early-access flag, a model, and per-run
spend, and CI is macOS with no guaranteed entitlement. netresearch made the same
call: their `evals.json` gets structural validation only on PRs, while
deterministic shell tests do the gating.

Deliverable is a documented manual runner plus a README section. A follow-up
issue tracks CI wiring if `plugin eval` reaches GA.

## Out of scope

- Portability of kaisen/plans to other repos (separate tranche).
- Careful per-command cases — tranche 2, scoped to Part A survivors.
- Other plugins' evals — later tranches.
- Any command deletion. Part A measures and recommends.
- A `tests/` suite for `commit-commands-jj` (layer-2 gap; file separately).

## Definition of done

1. `.github/scripts/run-evals.sh` exists, is bash 3.2-safe, and is documented.
2. `.github/tests/test-run-evals.sh` covers: zero-match glob aborts;
   both-arms-zero classified "broken" not "no gap"; delta gate arithmetic
   against a committed `aggregate-result.json` fixture, **including a
   null-delta case asserting the tripwire fires**; `--allow-tools` guard; both
   discovery formats; execution under `/bin/bash`.
3. Part B's four cases exist, each ablation-checked, non-discriminating ones cut
   with the cut recorded.
4. A committed exemplar `case.yaml` documents the schema by working example.
5. Part A's triage table is produced and written up, with per-arm pass counts
   and a recommendation per command.
6. Defects found are fixed or filed. The suite is expected to find real bugs;
   finding none is a reason to distrust the cases.
7. `commit-commands-jj`'s version is bumped (#84).
8. `**/evals/results/` gitignored — defence in depth behind `--output-dir`, for
   the path reachable when someone calls `claude plugin eval` directly. The
   `**/` prefix is required: gitignore anchors any pattern containing a
   mid-string slash to its own directory, so a bare `evals/results/` matches
   only a root-level dir that never exists while the real path stays tracked.
9. Full test suite green in `@` after fan-in, run by hand — the combined-result
   gate from `project_kaisen_lessons`.

## Risks

- **The suite becomes decorative.** Primary risk; mitigated by ablation as a
  hard gate, the both-arms-zero guard, and reporting cut cases.
- **Early-access flag disappears.** Runner breaks. Contained: manual, gates
  nothing, fails loudly.
- **Part A's thin cases understate a command's value.** Mitigated by `runs: 3`,
  per-arm counts, the validity precondition, and treating output as measurement.
- **Cost creep.** Bounded by a default `--max-cost-usd` in the runner. Note its
  semantics: on breach it exits 2 and skips paid graders while free ones still
  score, producing partial results a naive delta gate would misread — the gate
  must check for the breach exit before trusting deltas.
