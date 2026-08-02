# Plugin coverage map — what is tested where, and which surface metric predicts defects

**Written 2026-08-02**, after a week that produced #137, #139, #143, #145 and #146.
Read this before deciding where to spend testing effort. It is a map, not a plan —
per `docs/eval-triage-2026-07.md` §5, nothing here is grounds for deleting a plugin.

---

## 1. Coverage today

| plugin | jj invocations in markdown | prose linted? | script/behaviour tests | usage |
|---|---:|---|---:|---|
| `commit-commands-jj` | 333 | **yes** — 117 checks | 15 behavioural assertions | frequent |
| `workspace-jj` | 83 | no | 3 suites | occasional |
| `peer-review-jj` | 34 | no | 1 suite | occasional |
| `project-setup-jj` | 21 | no | 4 suites (hook: 151 assertions) | load-bearing |
| `agent-helpers-jj` | 8 | no | 2 suites (12 assertions) | constant |

**146 jj invocations across four plugins are unvalidated.** Nothing catches a
removed flag in any of them — the class that reached for `jj git push --allow-new`
three separate times.

The lint that closes this is `plugins/commit-commands-jj/tests/test-command-invocations.sh`.
It hardcodes `CMDS="$(dirname $0)/../commands"`, which is the only thing scoping
it to one plugin. Generalising it to walk every plugin's markdown would take
coverage from ~117 checks over one plugin to ~250+ over five.

### Two different things both called "testing"

- **Prose testing** — extract jj invocations from markdown and validate them.
  Three sources per file, and they are easy to miss: fenced code blocks,
  `` !`…` ``-injected Context commands (which **auto-execute** on every invocation),
  and `| git … | jj … |` translation-table cells. The table cells went unnoticed
  until #145; the injected commands are the most important, since a bad flag there
  breaks the command immediately rather than merely misleading the model.
- **Script/behaviour testing** — exercise the shell. `agent-helpers-jj` has good
  coverage of this kind after #146 and *none* of the prose kind. They are not
  substitutes.

---

## 2. Three ways to measure "surface", and which one actually predicted a bug

The same question — *where is the risk?* — gives three different answers.

| metric | winner | share |
|---|---|---|
| command count | `commit-commands-jj` | 16 of 23 (~70%) |
| prose volume | `workspace-jj` | 1044 lines (38%) |
| usage frequency | `agent-helpers-jj` | constant |

**Prose volume** looked like the right metric, because #79's defect-rate finding
is stated per unexercised file (~5–9 defects each) and was measured **on kaisen
itself** — nine defects in one run, then a tenth. By that logic the largest
unexamined surface is `kaisen/SKILL.md` at **1019 lines**: bigger than any three
`commit-commands-jj` files combined, 3× `finish.md`.

**Usage frequency won.** The live defect found that week was in `agent-helpers-jj`
— **59 lines, 2% by volume, last on the table**. `jjcheckpoint` used
`--ignore-working-copy`, so the op id it returned named a state predating any edit
not yet snapshotted, and `Write`/`Edit` never snapshot. Restoring to it dropped
those edits silently (#146).

> **Volume tells you where undiscovered defects are likely to be sitting.
> Frequency tells you which ones will actually hurt.** A silent restore-point bug
> in 59 lines called constantly beat 1019 lines run occasionally.

Note that invocation counts (§1) track volume, not frequency, so they inherit the
same caveat. `agent-helpers-jj` is bottom of that list too.

Kaisen remains the largest unexamined prose surface in the repo. That part stands.

---

## 3. Prose is a ~1-in-6 mechanism

Measured 2026-08-01 from subagent transcripts (`<session>/subagents/agent-*.jsonl`,
counting `Skill` calls — ground truth, not narration):

| request wording | invoked |
|---|---:|
| *"get rid of this work and let's move on"* | 1 / 10 |
| *"I want to discard this change"* | **3 / 3** → `abandon` |
| *"finished with this development work — push/squash/keep/discard?"* | **3 / 3** → `finish` |

Trigger rate tracks how closely the request matches the command's `description:`.
`abandon` is documented as *"Discard a jj change"* and fires on ordinary phrasing;
`finish` says *"Finish development work"* and does not.

Two consequences:

1. **A prose fix is worth its measured effect × the load rate.** A change that
   takes a hazard 3/3 → 0/3 but only loads 1 run in 6 is worth ~17% of face value.
2. **Deterministic assertions are the enforcement layer.** They run on 100% of
   PRs. Prose does not. When a finding is durable, pin it — do not rely on having
   written it down in a command file.

Corollary for grader design, learned expensively: **prose that prevents a hazard
reads as a null to a grader written at the hazard.** The primary observable for
#137's treatment arm was "does it hand back `--what repo`" — 1/3, apparently a
miss. But that advice is conditional on having deleted a pushed bookmark, and the
prose stopped 3/3 from doing that. Grade the harm, not the remedy.

---

## 4. The staleness layers — three, and they rot independently

| layer | where | made current by |
|---|---|---|
| 1. source | `plugins/<name>/` | merging to main |
| 2. cache | `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` | `marketplace update` **+** `plugin update` **+ restart** |
| 3. installed | e.g. `~/.config/jj-agent-helpers/`, project `.claude/hooks/` | **re-running that plugin's setup command** |

`claude plugin update` does **not** touch layer 3. #146 fixed `jjcheckpoint` in
layers 1 and 2 while the shell kept sourcing the buggy copy from layer 3.

**The ordering trap:** `/agent-helpers-setup` copies from `${CLAUDE_PLUGIN_ROOT}`,
which points at the version *the session loaded at startup*. Running setup before
restarting faithfully reinstalls the old file and reports success. Correct order:

```
claude plugin marketplace update <marketplace>
claude plugin update <plugin>@<marketplace>
# RESTART Claude Code   ← before setup, not after
/<plugin>-setup
exec zsh                # layer 3 is sourced by the shell
```

**Always verify by content, never by the version message.** Every step above
reports success regardless. `grep` for a sentinel from the actual change.

Related: subagents also load the session-start plugin version, so an in-session
A/B of a prose change silently measures the old prose. Make an agent quote the
prose back before trusting any such run.

---

## 5. What this implies

- **Highest coverage-per-effort:** generalise the invocation lint past
  `commit-commands-jj`. Deterministic, finds a recurring class, mostly deleting a
  hardcoded path.
- **Highest unexamined risk:** `kaisen/SKILL.md`. Large, orchestrates parallel
  agents across workspaces, and is the concrete exposure for #140 (Context blocks
  gather from the session cwd, not the target repo).
- **Don't pay to measure ceremony.** Prose prescribing steps the model already
  takes is measurably inert — #132's redundant `jj bookmark delete` was ignored
  0/3 *with the command open*. Prose carrying a fact the model cannot derive
  (`--what repo`, `jj undo` being sequential) is what pays.
- **Default to letting real use surface work.** Every defect found this week came
  from *running* something, never from reading it.

## Related

- `docs/eval-triage-2026-07.md` — tranche 1; §3 the working recipe, §2 three ways a case reports green while measuring nothing
- `docs/eval-command-triage-2026-07.md` — tranche 2; why command prose cannot be measured on the eval harness
- #138 — five measured instrument constraints in its comments, and the trap-signature checklist
- #140, #141 — the shipped defects this map points at
