# Eval triage — 2026-07 (issue #79, tranche 1)

Date: 2026-07-26
Issue: #79 — "~20 user-facing commands have never been executed"
Spec: `docs/specs/2026-07-20-eval-suite-design.md`
Plan: `docs/plans/2026-07-20-eval-suite-plan.md`
Status: tranche 1 measurement complete; Task 8 (documentation, issue filing,
final verification) still open

**This is a map, not a prune list. No command is proposed for deletion.**
See §5 before reading any number here as a recommendation.

---

## What this document is

The spec planned two deliverables for tranche 1: **Part B**, a handful of hook
and invariant eval cases, and **Part A**, a 16-command ablation sweep producing
a triage table.

Part B shipped. **Part A did not, and the reason is the result.** Three
probes — costing $1.63 rather than the $7 the sweep was budgeted — refuted
Part A's design at the mechanism level, one measurement at a time. The sweep was
never run and the 16 generated cases were removed before landing.

So this document is not the triage table. It is the record of what was actually
measured: the deltas Part B earned, the three separate mechanisms that killed
Part A's design, and the prompting-and-grading methodology the probes proved
works, handed to tranche 2 in a state it can pick up directly.

A triage table built on the refuted mechanism would have been sixteen rows of
noise reported as data. That is precisely the failure the spec was written to
prevent ("a green suite that cannot fail is worse than no suite, because it
terminates the inquiry"). Catching it at $1.63 instead of publishing it at $7 is
the tranche working as designed.

---

## 1. What tranche 1 measured

### 1.1 Part B — three ablation-checked cases

All three were run with `--ablation with-without` at `runs: 2` per arm.

| Case | with | without | Δ | pass (with) | pass (without) | Verdict | Outcome |
|---|---|---|---|---|---|---|---|
| `hook-blocks-raw-git` | 1.00 | 0.00 | **+1.00** | 2/2 | 0/2 | DISCRIMINATING | **shipped** |
| `hook-blocks-git-internals` \* | 1.00 | 0.00 | **+1.00** | 2/2 | 0/2 | DISCRIMINATING | **shipped** |
| `hook-allows-jj-git-and-gh` | 1.00 | 1.00 | **0.00** | 2/2 | 2/2 | NO_GAP | **cut → layer 2** |

> **\* `hook-blocks-git-internals` is misnamed, and these are not two branches
> of coverage. Both shipped cases measure the same branch.**
> Its prompt is `git rev-parse HEAD`. In
> `plugins/commit-commands-jj/scripts/block-raw-git.sh` the `has_raw_git` test
> matches any bare `git` token at command position and returns the **raw-git**
> deny message at line 49 — before the internals branch at line 62 is ever
> reached. The case's grader regex,
> `(BLOCKED|blocked|not allowed|denied|internals)`, passes happily on that
> raw-git message. Verified offline against the hook: the internals branch
> answers only `.git/` **path** access; both commands the internals regex
> names (`git config`, `git rev-parse`) are shadowed by the raw-git branch.
>
> So the internals branch has **zero eval coverage**. It is reached only by the
> free layer-2 assertion added in Task 5
> (`tests/test-block-raw-git-gating.sh:17-23`, which documents the shadowing in
> a comment). A reader seeing two rows at Δ +1.00 must not conclude two hook
> branches are covered — one branch is covered twice.

> **RESOLVED 2026-07-29 (#103).** The finding above stands as written — it was
> correct — but it no longer describes the shipped case. The prompt is now a
> dot-git path read, which the raw-git branch cannot shadow, and the grader is
> `[Gg]it internals`, wording the raw-git message does not contain. Re-measured
> with ablation: with 1.00 / without 0.00, **Δ +1.00**, 4 runs, $0.35, traces
> retained — the without-arm read `ref: refs/heads/main` at exit 0, so the delta
> reflects the wall rather than an absent file. The scaffold is colocated for
> that reason, and `tests/test-eval-scaffold.sh` pins it.
>
> The two shipped cases now cover two different branches. The lesson in this
> section is unchanged and is the durable part: **a grader measures its own
> assertion, never the case's title**, so anchor on wording unique to the
> behaviour under test. The permissive `(BLOCKED|blocked|…)` alternatives are
> exactly what let this case pass against the wrong branch for a whole tranche.
>
> This is §6's own lesson landing in this document's own results table: **a
> grader measures its own assertion, not the case's title.** The case name and
> `description:` still say "git internals"; correcting them is open work, and
> the Δ +1.00 itself is real — it is a genuine measurement of the raw-git
> branch, just not of the branch the name promises.

Per-run detail, from the result JSONs:

- **`hook-blocks-raw-git`** — grader `reports-blocked` (regex, weight 1) passed
  on both with-arm runs and failed on both without-arm runs. Turns: with 3, 3;
  without 2, 2. Cost `$0.4536`. `partial: false`.
- **`hook-blocks-git-internals`** — same single grader, same 2/2 vs 0/2 split.
  Turns: with 3, 4; without 3, 6. Cost `$0.6828`. `partial: false`. Measures the
  raw-git branch, per the note above.
- **`hook-allows-jj-git-and-gh`** — two graders, `jj-git-ran` and `not-blocked`,
  both passed on all four runs across both arms. Turns: with 7, 5; without 9, 8.
  Cost `$0.9956`. `partial: false`.

The cut is not a failure of the hook; it is a failure of the *case*. The
assertion is the **absence** of a deny, and the ablation's `without` arm has no
hook to produce a deny either — so both arms pass whether or not the negative
lookahead in the raw-git regex works. The case was structurally incapable of
distinguishing "correctly passed through" from "no hook at all". The spec had
already reached that conclusion analytically for the #45 pass-through invariant
and routed it to layer 2 before spending; `hook-allows-jj-git-and-gh` reached
the same place empirically, for the same reason, at $0.9956.

Both sets of assertions now live in
`plugins/commit-commands-jj/tests/test-block-raw-git-gating.sh`, where the hook
is exercised as the pure stdin/stdout function it is — deterministically, for
free, and inside CI's test glob. That suite reports **5 passed, 0 failed**.

### 1.2 Part A — three probes, no sweep

| Probe | Prompt form | runs/arm | with | without | Δ | Reported verdict |
|---|---|---|---|---|---|---|
| **P2 run A** | literal `/describe …` | 1 | 0.50 | 0.50 | 0.00 | NO_GAP |
| **P2 run B** | literal `/commit-commands-jj:describe …` | 1 | 1.00 | 0.50 | +0.50 | DISCRIMINATING |
| **P3** | natural language, no command named | 3 | 0.83 | 0.50 | +0.33 | PARTIAL |

Both P2 verdicts are artifacts, for reasons §2 dissects. P3 is a real
measurement and is read in §4.

Turn counts are the tell, and they are the single most useful column in this
table:

| Probe | with turns | without turns |
|---|---|---|
| P2 run A | 0 | 0 |
| P2 run B | 2 | 0 |
| P3 | 6, 6, 6 | 6, 5, 8 |

In P2 run A **neither arm executed a single turn**, and the harness reported the
case green. In P2 run B only the with arm ran. Only under P3's natural-language
prompt did both arms actually do work.

### 1.3 Spend

| Artifact | What | Cost |
|---|---|---|
| `eval-results-95904` | `hook-blocks-raw-git` | $0.4536 |
| `eval-results-17927` | `hook-blocks-git-internals` | $0.6828 |
| `eval-results-21782` | `hook-allows-jj-git-and-gh` | $0.9956 |
| `eval-results-20375` | P2 run A | $0.0093 |
| `eval-results-21686` | P2 run B | $0.1087 |
| `eval-results-27873` | P3 | $1.5150 |
| | **total** | **$3.77** |

Summing the six `cost_usd` fields gives `$3.7651`. The ledger's per-task figures
round to the same total. The one further run reported at `$0.00` is the **schema
pre-check** — a prompt-stripped copy of the case, run first so that any grader
error surfaces at validation for free; it aborts before the paid path and never
writes an aggregate, which is why it has no result JSON and is not in this table.

Task 6 — the entire Part A investigation — cost **$1.63** against a $7 sweep
budget (the three retained JSONs sum to `$1.6331`; the SDD ledger records $1.64,
which is the same spend rounded per-run), and every blocking finding except the
schema rejection was reached by spending. The schema rejection (§2.1) was proved at **$0.00**, by a controlled
pair of throwaway cases that could never reach the paid path.

---

## 2. Why Part A did not ship: three separately-measured mechanism failures

These are three independent defects, each measured on its own. Fixing any one of
them would have left the other two intact. That matters for tranche 2: the
temptation is to remember this as "Part A was blocked", and then to re-land it
after fixing the blocker one remembers.

### 2.1 `weight: 0` is rejected by the case schema — CONFIRMED, $0.00

Part A's design hinged on a *validity precondition*: a `tool_used` grader
asserting "the command was actually exercised", recorded but not scored. The
plan implemented "not scored" as `weight: 0`.

The CLI's case schema declares weight as a positive number. All 16 generated
cases failed validation identically:

```
graders.0.weight: Number must be greater than 0
```

Isolated with a controlled experiment: two throwaway cases differing only in
`weight`, both also missing `execution.prompt` so validation could never reach a
paid run. The `weight: 0` copy failed on weight; the `weight: 1` copy cleared
the weight check and failed only on the missing prompt. `weight` was the sole
offender.

The correct mechanism exists and is a different feature entirely: **`arm:
with-only`**, which the runner auto-applies to any `tool_used` grader whose
`tool` is `Skill`. It excludes the grader from the score in *both* arms while
still recording pass/fail in `runs[].graders[]`. This was confirmed by
measurement in P2 — the with arm printed `invoked-command [with-only, not
scored]`, the JSON carried `with_only: true`, and the grader was **absent
entirely** from `runs_without[].graders[]` (3 graders in the with arm, 2 in the
without arm). It did not move the score in either direction.

One consequence for anyone reading the old plan: its "column 3 tripwire" — jq
asserting the precondition never passes in the without arm — becomes vacuous
under `with-only`, because the grader is filtered out of that arm by
construction rather than measured there. It is no longer a real check.

### 2.2 A literal `/cmd` prompt records no tool call — and a bare `/cmd` resolves to nothing — MEASURED

Part A's prompts were literal slash-command invocations, on the spec's reasoning
that slash commands are user-invoked rather than model-invoked, so the eval
should simulate the user typing one. Two independent things go wrong.

**(a) An expanded slash command is not a tool call.** In P2 run B the with arm
demonstrably executed the command — the trace shows a `Bash` call running
`jj describe -m "Add notes.txt"` and a 2-turn successful result — and yet the
`tool_used` precondition reported `Skill called 0x (expected 1..∞)` and failed.
A prompt beginning with `/` is expanded client-side into the prompt text; it
never becomes a tool call, so **no `tool_used` grader can observe it**. The
precondition Part A's design required is not merely misconfigured, it is
unobtainable for literally-invoked commands.

*Measured for `Skill` only.* "`SlashCommand` would fail identically" is an
**inference** from the same client-side-expansion mechanism, not a measurement:
`Skill` is the only tool that was actually run as the grader's `tool`, and
`SlashCommand` is denied outright by the CLI in this configuration (§7, Gap A),
so it could not have been measured without first fixing that.

**(b) Commands are namespaced, so the bare form never resolved at all.** The
generated prompts used `/describe …`. The with arm's `system/init` line shows
the plugin loaded correctly and registered the command as
`commit-commands-jj:describe`. Bare `/describe` does not exist — plugin loaded
or not. Both arms therefore returned:

```json
{"num_turns":0,"total_cost_usd":0,"is_error":false,"subtype":"success",
 "result":"Unknown command: /describe"}
```

`subtype: "success"`, `is_error: false`, zero turns, and a score reported green.
Nothing in the harness or the runner flags it. Had the sweep run as planned, all
16 cases would have produced this — 96 runs of nothing, reported as a clean
NO_GAP sweep.

### 2.3 A 0-turn arm banks free score from vacuously-passing negative graders — MEASURED

The generated cases' only scored grader was `no-raw-git`: a negative
`tool_used` at `min: 0, max: 0`, failing if the model shells out to raw git. It
counts `Bash` calls **filtered by a raw-git pattern**, not all `Bash` calls — so
its "Bash called 0x" reading means "zero raw-git invocations", and a run making
several legitimate `Bash` calls still passes it.

A negative grader **passes when nothing happens**. So an arm that took zero
turns, cost nothing, and produced only the synthetic text `Unknown command: …`
still scored `0.50` — half marks for not doing the thing it never had a chance
to do.

That vacuous 0.50 is what manufactured P2 run B's verdict:

| Probe | Arm | turns | `invoked-command` | outcome grader | `no-raw-git` | score |
|---|---|---|---|---|---|---|
| P2 run B | with | 2 | fail (not scored) | PASS | PASS | **1.00** |
| P2 run B | without | 0 | *(filtered out)* | FAIL | PASS (vacuous) | **0.50** |

Δ **+0.50**, printed as **DISCRIMINATING** — the taxonomy's top verdict, the one
that means "ships". What it actually measured is that a command name resolves in
one arm and not the other. Sixteen such rows would have been a table of name
resolution wearing the costume of a behavioural finding.

The same vacuity produced P2 run A's symmetric `0.50 / 0.50 / Δ 0.00 NO_GAP`
out of two completely dead runs.

**And the spec's guard did not catch it.** The runner classifies both-arms-zero
as "broken, never no-gap" precisely to catch dead runs. Both arms here scored
`0.50`, not `0.00`, so the guard never fired. A negative-only grader lifts a dead
arm off the floor the guard is watching.

### 2.4 The fourth problem, which is a design gap rather than a mechanism

Recorded here because it is what made the first three fatal rather than
fixable. Once the precondition is correctly unscored — by any mechanism — the
generated cases had **no outcome grader left**. The only scored grader was a
negative invariant both arms satisfy whenever the model simply does not reach
for raw git. All 16 cases would have returned NO_GAP **by construction**,
independent of whether any command helped.

The CLI's own authoring guidance names this floor: every case needs at least one
outcome grader, and a `Skill` precondition must never be a case's only grader.
§3 is the methodology that satisfies it.

---

## 3. The methodology that works — hand-off to tranche 2

P3 was designed to test whether *anything* about Part A was salvageable. The
mechanism is. Tranche 2 should adopt this recipe as-is.

**The recipe:**

1. **Natural-language prompts.** Describe the task the way a user would. Do not
   name the command, do not use `/`. P3's prompt was, in full:

   > I just added notes.txt to this repo. The change I'm sitting on still has no
   > message attached to it, so I can't tell what it is when I look back at the
   > log later. Please sort that out for me.

   Both arms then genuinely execute, and the model keeps agency over whether to
   reach for the command — which is the thing worth measuring.

2. **A `tool_used` precondition on `tool: Skill`, `min: 1`, with `arm` left
   unset.** The runner auto-applies `with-only`. The grader records whether the
   model invoked a plugin command, and cannot move the score in either arm.
   Leave `arm` unset; do not set it by hand, and do not try to make it scored.

3. **At least one real outcome grader**, asserting the user-visible effect in the
   sandbox rather than the presence of a command invocation. P3's was
   `change-described-not-finalized`: the change ends up with a message referring
   to the file, and the assistant did not finalize or advance past it.

4. **`runs: 3` per arm.** This is what P3 ran. The spec explicitly rejected
   `runs: 1`: a single sample per arm yields a delta in {−1, 0, +1} with no
   confidence attached, and the noise is asymmetric, since a spurious `without`
   pass reads as the actionable verdict.

5. **Keep `SlashCommand` out of `allowed_tools`.** It buys nothing (§2.2) and the
   CLI denies it anyway, silently past the runner's guard (§7, Gap A). P3 dropped
   it. Do leave `Bash` in: the runner's default `--allow-tools Bash` is what
   satisfies the exit-7 tool-grant guard for a `Bash`-based grader, and a case
   declaring a gated tool the grant does not cover would otherwise score zeros.

**The measured evidence that it works, all from `eval-results-27873`:**

- **The model invoked the command on 3/3 with-arm runs.** Every with-arm run
  shows `Skill {'skill': 'commit-commands-jj:describe'}` in the trace, and
  `invoked-command` passing with `Skill called 1x (expected 1..∞)`. Zero
  occurrences in the without arm.
- **This overturns the spec's own premise.** The spec's Part A rewrite was
  founded on a review measurement that the model "never invokes the commands at
  all — it goes straight to Bash, with `Skill` and `SlashCommand` both called
  0×". That does not hold on this harness under a natural-language prompt with a
  with-only precondition in place. A model-initiated command invocation *does*
  go through the `Skill` tool and *is* observable.
- **Both arms ran real turns on every run** — with 6/6/6, without 6/5/8, at
  $0.23–$0.29 each. The dead-arm artifact of §2.3 is gone.
- **The precondition was recorded but not scored.** `with_only: true` on all
  three with-arm runs, and absent from `runs_without[].graders[]` entirely. That
  it cannot move the score is shown directly by P2 run B, where
  `invoked-command` **failed** and the with arm still scored a full **1.00**.

One scaffold defect noticed in passing and worth fixing before re-use: P3's
scaffold wrote `.jjconfig/config.toml` *inside* the work tree, so it appeared as
a second added file and both arms described "notes.txt and jj config". Harmless
to the result, but it muddies "what changed". Move scaffold config outside the
work tree.

The two shipped scaffolds now do exactly that, and for a second reason found in
the #79 review: the CLI spawns `scaffold.sh` with a fixed env whitelist and runs
the turn in a **separate process**, so an `export JJ_CONFIG=…` in a scaffold
configures nothing the agent can see. `HOME` is what the two processes share, so
the scaffolds write jj's user config inside the sandbox home — out of the work
tree and actually visible to the turn. Asserted in
`plugins/commit-commands-jj/tests/test-eval-scaffold.sh`.

---

## 4. The one command actually measured: `describe`

One command out of sixteen has a real ablation number.

**`describe` — with 0.83 / without 0.50 / Δ +0.33 / PARTIAL** (3 runs per arm,
`eval-results-27873`). Per-arm pass counts: with **2/3**, without **0/3**.

The aggregate is not the finding. The grader-by-grader attribution is:

| Grader | with | without | Contribution to Δ |
|---|---|---|---|
| `invoked-command` (with-only) | 3/3 | *(filtered out)* | 0 — never scored |
| `change-described-not-finalized` (outcome) | **3/3** | **3/3** | **0.00** |
| `no-raw-git` (negative invariant) | 2/3 | 0/3 | **+0.33** |

**The outcome grader passed 3/3 in both arms.** The 2026 base model, given the
natural-language prompt and no plugin at all, described the change correctly and
did not finalize it — unprompted, on every run. On the thing `describe.md`'s
prose is actually *about*, the measured gap is **zero**.

The entire +0.33 came from `no-raw-git` — a negative `tool_used` grader that
counts only the **pattern-matching** raw-git `Bash` calls, not all `Bash` calls,
which is why a run making three or four legitimate `Bash` calls still reports
"Bash called 0x".

**And the mechanism behind that +0.33 is not the hook blocking anything.** The
traces are unambiguous:

| P3 with-arm run | `no-raw-git` | did the model reach for git? | did the hook fire? |
|---|---|---|---|
| run 1 (`claude-eval-Ty9b0d`) | **PASS** | no | no |
| run 2 (`claude-eval-TshZtm`) | **FAIL** | yes | **yes** — `BLOCKED: Raw git commands…` |
| run 3 (`claude-eval-yW9wum`) | **PASS** | no | no |

On the two with-arm runs where the grader passed, the model never issued a git
command at all, so the hook never fired. On the one run where the hook *did*
fire, the grader **failed** — because it counts the attempt, not the outcome.
**Not one with-arm grader pass is attributable to the hook blocking anything.**
The with-arm advantage comes from the loaded plugin steering the model to jj
*before* it reached for git; the hook, when it fired, was too late to save the
grader. In the without arm all 3/3 runs reached for git with no hook present.

Either way the delta belongs to the plugin's raw-git avoidance, not to
`describe`'s prose — and that is the **hook** invariant `hook-blocks-raw-git`
already covers at **Δ +1.00**, with a case built for it. A re-landed Part A
`describe` case would be measuring the hook a second time, through a
command-shaped hole.

Note also that the with arm was not clean: `no-raw-git` failed there too, on 1 of
3 runs (2/3, not 3/3) — run 2 above, where the model attempted raw git, was
blocked, and recovered to `jj describe -m …`. Correct end-to-end behaviour,
scored as a failure.

**The generalisable lesson, and the most portable thing in this document:**

> An aggregate delta can be carried entirely by a grader that belongs to a
> different case. Check attribution grader-by-grader before reading a delta as a
> verdict.

`describe` at Δ +0.33 PARTIAL looks, from the TSV row alone, like a command whose
prose does modest measurable work. It is not. It is a command whose prose does
*no* measurable work here, sitting next to a hook that does a great deal, in a
case that scored them together. A triage table reporting only `with / without /
Δ / verdict` would have printed the wrong conclusion in a column labelled
"verdict" — and would have done so for every one of sixteen rows carrying the
same `no-raw-git` grader.

---

## 5. This is a map, not a prune list

This framing comes from the spec and survives the re-scope unchanged.

`commit-commands-jj` is a jj-native port of `anthropics/claude-plugins-official`'s
commit-commands; this repo began as a fork of it. The command set exists partly
to mirror upstream, and **upstream parity is itself a reason to keep a command a
model could limp through without** — consistency across the two repos, and
pinning behaviour that could otherwise drift, are values no ablation number can
see.

Therefore:

- **No command is proposed for deletion.** Not `describe`, not any of the other
  fifteen. Nothing in this document licenses removing anything.
- A low delta means *"the prose adds little measurable behaviour on this prompt,
  under this grader, at this sample size"*. It is information about **where
  tranche-2 test effort belongs**. It is not evidence about a command's value,
  and it is certainly not grounds for deletion.
- The single measured command is measured at Δ +0.33 with **zero** of that delta
  attributable to its own prose. Read as a hit list, that would be an argument to
  delete `describe`. That reading would be wrong on the facts of §4 and wrong on
  the policy of this section.

If a future reader arrives here looking for a list of commands to cut, the
correct response is that this document does not contain one and was explicitly
written not to.

---

## 6. Method and limits

Stated plainly, because the numbers above are small and the temptation to
over-read them is real.

- **Sample size is 1–3 runs per arm.** Part B ran at `runs: 2`, P3 at `runs: 3`,
  the P2 probes at `runs: 1`. Every delta here is a **point estimate with no
  confidence interval attached**.
- **One command was measured, out of sixteen.** `describe`, once, on one prompt,
  with one grader set, judged by the CLI's default judge model (the runner does
  not pass `--judge-model`). Nothing here generalises to the other fifteen
  commands, and the §4 result does not even generalise to `describe` under a
  different prompt.
- **This is a screen, not a verdict.** Its output is where to spend tranche-2
  effort, not a ruling on any command.
- **A grader measures its own assertion, not the case's title.** §4 is the
  worked example.
- **The eval layer replaces nothing.** Layer 2 — the repo's deterministic shell
  suites — still does the CI gating. Evals gate nothing, are run by hand, and
  cost money per run.
- **Result JSONs live in the OS temp directory** (`/var/folders/…`) and will be
  reaped. Every number in this document was read from them while they existed;
  once they are gone, this document and the SDD ledger are the record.

**What would change the conclusion:**

- Running `describe` at higher `runs` and finding the outcome grader failing in
  the without arm — i.e. that its 3/3 was sampling luck rather than base-model
  competence. That would move `describe` from "prose adds nothing measurable
  here" to a genuine partial.
- A different outcome grader for `describe` targeting a claim the current one
  does not — the current one grades the user-visible outcome, and the prose makes
  narrower claims that a sharper grader might catch the base model violating.
- Any of the other fifteen commands measuring a non-zero delta on an outcome
  grader with `no-raw-git` removed from the case. This is the obvious tranche-2
  experiment and the cheapest way to make §4's attribution finding actionable:
  **drop `no-raw-git` from command cases entirely**, since a dedicated case
  already covers it at Δ +1.00, and read the outcome grader alone.
- Evidence that natural-language prompting biases invocation — P3 measured 3/3
  `Skill` invocations on one command with one phrasing, and a prompt that
  telegraphs the command more than intended would inflate that.

---

## 7. Runner gaps found and logged, not fixed

Three defects in `.github/scripts/run-evals.sh` surfaced during the probes. All
three were left unfixed at the time and are recorded here so they are not lost.
**All three are now closed** (#102). The diagnoses are kept because the
measurements behind them are what the fixes are anchored to.

**Gap A — `SlashCommand` is missing from the exit-7 guard's gated list.**
The guard matched `Bash|Write|Edit|WebFetch|mcp__*`. A case declaring
`SlashCommand` in `allowed_tools` passed the guard clean while the CLI denied
the tool at runtime:
`cmd-describe: denied tools (pass --allow-tools to grant): SlashCommand`. The
guard exists precisely to prevent an ungranted tool silently zeroing an arm, and
it had a hole for the one tool Part A depended on.

**Closed**, but not as originally framed. `claude plugin eval --help` (2.1.220)
documents the operator grant as exactly "Bash, Write, Edit, WebFetch, mcp__*" —
the guard's grantable list was already correct and complete. `SlashCommand` is
gated by a *different* mechanism and is absent from that set, so **no
`--allow-tools` value can ever satisfy it**. Adding it to the grantable list
would have produced an abort telling the operator to pass a flag value the CLI
rejects. It is instead a separate category — declared, gated, ungrantable,
therefore unmeasurable by ablation — and the exit-7 diagnostic now says so.
Granting it deliberately does *not* rescue the case.

**Gap B — negative-only graders score vacuously on a 0-turn arm.**
Dissected in §2.3. A dead arm banks free score, inflating the delta, and lands
above the both-arms-zero floor so the runner's "broken, never no-gap" guard never
fires.

**Closed**, on the second attempt. The first was withdrawn under review, and
the reason is worth keeping because it is the trap this whole section invites.

The `{"num_turns":0,...}` record quoted in §2.2 above is the CLI's **per-run
result message**, not a field of `aggregate-result.json`. The aggregate is what
`classify()` reads, and its per-run entries call the field **`turns`**:

```
.cases[].runs[]  keys = cost_usd, duration_seconds, error, graders,
                        judge_cost_usd, score, started_at, trace_path, turns
```

A tripwire keyed on `num_turns` fires on every real run: the sweep pays its
full budget, completes, and is then discarded with a schema-drift error. Every
fixture asserting `num_turns` was hand-written, so the suite was green against
a field the CLI never emits.

What closed it:

- A real captured aggregate is committed verbatim at
  `.github/tests/fixtures/evals/real/`. Mutation-measured: with the runner
  **and** every hand-written fixture renamed to `num_turns` — the withdrawn
  attempt's exact world — 71 assertions pass and only the real-capture
  assertion fails. It is the single input that can disagree with the author.
- A dead arm is a **per-case verdict**, `DEAD_ARM(with|without|both)`, failing
  the gate in strict and report mode like `BROKEN`. Not a whole-file abort:
  `.partial` aborts because it is a whole-run property, whereas one dead case
  must not discard the other 15 verdicts of a paid 16-case sweep.
- `turns` is read at the fixed path. Recursive descent plus `max` lets any
  nested counter mask a dead arm — the very drift such a search would exist to
  survive.
- Cases are identified by position, never by `.name`, which may be absent,
  null or empty.

Deliberately **not** covered: an arm where only *some* runs took zero turns. It
still inflates the mean, but there is no measurement of legitimate run-to-run
variance, and a threshold guessed now would abort real sweeps. Revisit with
tranche-2 data.

Also still an inference, and worth knowing: neither captured aggregate contains
a dead arm — both are healthy (turns 3–9). The dead-arm fixtures are therefore
hand-written, so the *shape* of a real 0-turn run entry is assumed, not
measured. If a real dead arm carries no `turns` key at all, the turn-detail
tripwire reports schema drift rather than `DEAD_ARM` — wrong diagnosis, but
loud, and only on the case being detected rather than on every run. Capturing
one real dead arm would close this.

**Gap C — zero loadable cases kills the runner on `find` before `classify()`.**
When the CLI loads 0 cases it writes no output directory, so
`RESULT="$(find "$OUT_DIR" -name aggregate-result.json | head -1)"`
(`run-evals.sh:419`) fails and `set -e` kills the script at that line. The
operator sees a bare `find: … No such file or directory` and exit 1 instead of a
diagnostic naming the load failures, and `classify()` never runs. Any workflow
that depends on the `result JSON:` line printed two lines later inherits this.
**Closed** in the #79 review fix-wave: an empty `RESULT` now exits 3 with a
diagnosis, and the same fix covers a missing `plugins/` directory (a
wrong-cwd invocation, which previously exited 1 with no output at all).
Both are asserted in `.github/tests/test-run-evals.sh`.

### Authoring hazard, if tranche 2 writes another case generator

Part A's generator wrote each `case.yaml` from an **unquoted** heredoc — required
so `$cmd` and `$prompt` expand — whose body contained backticked prose
(`` `jj git push` ``, `` `jj describe -m "…"` ``). Bash performs command
substitution on backticks inside an unquoted heredoc. Run verbatim against stub
binaries, the generator **executed 32 pushes and 16 description rewrites**,
exited **0**, and emitted a `case.yaml` whose comment block had been silently
gutted where the backticks used to be. Nothing in the output signalled it. The
fix is one character per backtick (`` \` ``); the lesson is that an unquoted
heredoc containing documentation prose is a live shell, and its failure mode is
green.

---

## 8. Artifact index

Result JSONs, all with `schema_version: "1.0"` and `partial: false`, all under
`/var/folders/bc/x1cqjcfx5cq1v24n2ddl21bm0000gn/T/`:

| Directory | Case | Result |
|---|---|---|
| `eval-results-95904/` | `hook-blocks-raw-git` | 1.00 / 0.00 / +1.00 |
| `eval-results-17927/` | `hook-blocks-git-internals` (measured the raw-git branch as it stood then — see §1.1, resolved under #103) | 1.00 / 0.00 / +1.00 |
| `eval-results-21782/` | `hook-allows-jj-git-and-gh` | 1.00 / 1.00 / 0.00 |
| `eval-results-20375/` | P2 run A (literal bare `/cmd`) | 0.50 / 0.50 / 0.00 |
| `eval-results-21686/` | P2 run B (literal namespaced `/cmd`) | 1.00 / 0.50 / +0.50 |
| `eval-results-27873/` | P3 (natural language, `runs: 3`) | 0.83 / 0.50 / +0.33 |

P3 trace directories (`<dir>/out/trace.jsonl`), which §4's attribution rests on:

| Arm / run | Directory | `no-raw-git` |
|---|---|---|
| with 1 | `claude-eval-Ty9b0d/` | pass |
| with 2 | `claude-eval-TshZtm/` | fail (hook fired) |
| with 3 | `claude-eval-yW9wum/` | pass |
| without 1–3 | `claude-eval-auuDpM/`, `claude-eval-Ktbsfc/`, `claude-eval-Pcjg9J/` | fail |

Shipped cases in the tree:

- `plugins/commit-commands-jj/evals/hook-blocks-raw-git/`
- `plugins/commit-commands-jj/evals/hook-blocks-git-internals/`

Layer-2 test carrying the cut case's assertions:

- `plugins/commit-commands-jj/tests/test-block-raw-git-gating.sh` (5 passed, 0 failed)

Removed before landing: all 16 `plugins/commit-commands-jj/evals/cmd-*/`
directories and `.github/scripts/gen-command-cases.sh`. They were added and
removed inside the same change, so they cancel; the net diff of that change is
the `commit-commands-jj` version bump to `0.4.0`.
