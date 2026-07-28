# Dead-Arm Detection in run-evals.sh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect an ablation arm that executed zero turns and report it as a per-case verdict, so a run that measured nothing can never read as a real delta.

**Architecture:** Extend the existing `classify()` in `.github/scripts/run-evals.sh`. A new schema tripwire requires `.cases[].runs[].turns`, and the existing TSV `jq` program gains a `dead()` helper that emits `DEAD_ARM(with|without|both)` alongside `BROKEN`/`REGRESSION`/`NO_GAP`/`PARTIAL`/`DISCRIMINATING`. The gate fails a dead arm in both strict and report mode. No new exit code, no whole-file abort, no second `jq` mechanism.

**Tech Stack:** bash 3.2 (macOS), `jq`, the repo's own shell test suites.

## Global Constraints

- **bash 3.2-safe.** No globstar, no associative arrays. Test with `/bin/bash`, never zsh.
- **jj, never raw git.** A PreToolUse hook blocks raw git and fires on your own tool arguments. Write files with Write/Edit, not bash heredocs.
- **The real field is `turns`.** `.cases[].runs[]` keys, verified against two captures from the 2026-07-26 probe (CLI 2.1.220): `cost_usd, duration_seconds, error, graders, judge_cost_usd, score, started_at, trace_path, turns`. The `num_turns` in `docs/eval-triage-2026-07.md` §2.2 is the CLI's **per-run result message**, a different artifact. Keying on `num_turns` is the exact defect this plan exists to avoid repeating.
- **Fixed path only, no recursive descent.** Read `.turns` at `.cases[].runs[]`. A recursive `..` search combined with `max` lets any nested counter mask a dead arm.
- **Identify cases by index, never by `.name`.** `.name` may be absent, null or empty; a `join` over names yields `""` and silently skips the case.
- **Every lint is written to FAIL FIRST.** A green first run proves nothing. Negative assertions anchor on wording unique to the behaviour under test, never on an exit code alone.
- **Prove non-vacuity by mutation.** Break the implementation, confirm the assertion flips.

## Design deviation from the brainstorm, and why

The approved design said to *fold* the runs/turns drift check into the existing delta/score type tripwire. **Do not fold it.** Both would then share one diagnostic and one exit code, so no assertion could tell which fired — precisely the F4 trap that made the delta/score invariant untestable in the withdrawn attempt.

Instead: leave the existing delta/score tripwire **byte-for-byte unchanged**, and add a second, separate tripwire immediately after it with its own distinct message. Same exit code (5) is fine; the messages are what assertions anchor on. Ordering matters — delta/score runs first, so `nulldelta.json`, `stringdelta.json` and `driftedscores.json` never reach the runs check and need no fixture changes.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `.github/scripts/run-evals.sh` | the runner and `classify()` | modify: add runs/turns tripwire, `dead()` in TSV + gate |
| `.github/tests/fixtures/evals/real/` | captured CLI ground truth | create: verbatim capture + provenance README |
| `.github/tests/fixtures/evals/*.json` | synthetic scenarios | modify: 8 files gain `runs`/`runs_without` |
| `.github/tests/fixtures/evals/deadarm*.json` | dead-arm scenarios | create: 3 files |
| `.github/tests/test-run-evals.sh` | the suite | modify: new assertions, anchor 3 old ones |
| `docs/eval-triage-2026-07.md` | §7 gap record | modify: mark Gap B closed |

---

### Task 1: Commit captured ground truth

**Files:**
- Create: `.github/tests/fixtures/evals/real/hook-allows-jj-git-and-gh-2026-07-26.json`
- Create: `.github/tests/fixtures/evals/real/README.md`
- Test: `.github/tests/test-run-evals.sh`

**Interfaces:**
- Produces: `$FIX/real/hook-allows-jj-git-and-gh-2026-07-26.json`, used by Tasks 2–4.

The source capture is at
`/private/tmp/claude-501/-Users-muloka-projects-sonder-hale-tools-claude-plugins/bf7f1ef7-ed9f-432d-9668-8b74563521c0/scratchpad/real-aggregates/hook-allows-jj-git-and-gh-aggregate-result.json`.
It lives in a session scratchpad and will be deleted; copy it before anything else.

This task's assertion is a **characterization test**, not fail-first: `classify()` does not yet require run detail, so it passes on arrival. It becomes load-bearing in Task 2, and Task 4's `num_turns` mutation is what proves it non-vacuous. That is stated here so a reviewer does not mistake it for a vacuous green.

- [ ] **Step 1: Copy the capture verbatim**

```bash
mkdir -p .github/tests/fixtures/evals/real
cp "/private/tmp/claude-501/-Users-muloka-projects-sonder-hale-tools-claude-plugins/bf7f1ef7-ed9f-432d-9668-8b74563521c0/scratchpad/real-aggregates/hook-allows-jj-git-and-gh-aggregate-result.json" \
   .github/tests/fixtures/evals/real/hook-allows-jj-git-and-gh-2026-07-26.json
```

Do not reformat, redact or prettify it. Machine paths, timestamps and costs stay. The entire value of this file is that nobody edited it.

- [ ] **Step 2: Verify the copy is byte-identical and carries `turns`**

```bash
jq -r '.cases[0].runs[0] | keys | join(", ")' \
  .github/tests/fixtures/evals/real/hook-allows-jj-git-and-gh-2026-07-26.json
```

Expected, exactly: `cost_usd, duration_seconds, error, graders, judge_cost_usd, score, started_at, trace_path, turns`

If `turns` is absent, STOP — the capture is wrong and the whole plan rests on it.

- [ ] **Step 3: Write the provenance README**

Write `.github/tests/fixtures/evals/real/README.md`:

```markdown
# Captured eval results — ground truth

Real `aggregate-result.json` output from `claude plugin eval`, committed
verbatim.

| File | CLI | Captured | Case |
|---|---|---|---|
| `hook-allows-jj-git-and-gh-2026-07-26.json` | 2.1.220 | 2026-07-26 | `hook-allows-jj-git-and-gh` |

**Do not hand-edit these files.** Recapture instead:

    bash .github/scripts/run-evals.sh --plugin commit-commands-jj --keep-temp

then copy the `aggregate-result.json` from the run's `--output-dir`.

They exist because #102's first fix keyed on `num_turns`, a field the CLI
emits in its per-run *result message* but not in the aggregate — where the
field is `turns`. The hand-written fixtures agreed with the mistake, so the
suite was green against a field the CLI never emits. A fixture nobody edited
cannot agree with a mistake.
```

- [ ] **Step 4: Add the characterization assertion**

In `.github/tests/test-run-evals.sh`, after the `row_count()` helper definition, add:

```bash
# Captured CLI output, committed verbatim (fixtures/evals/real/README.md).
# Every other fixture in this suite is hand-written, which means they can only
# ever confirm the author's model of the schema. #102's first fix keyed on
# `num_turns` and every hand-written fixture agreed with it; this file is the
# one input that can disagree. It is a characterization test until Task 2 makes
# run detail mandatory — the mutation in Task 4 is what proves it can fail.
REALFIX="$(cd "$(dirname "$0")" && pwd)/fixtures/evals/real"
REAL="$REALFIX/hook-allows-jj-git-and-gh-2026-07-26.json"
#
# `--gate report`, deliberately: this asserts the file CLASSIFIES, not that it
# passes. The captured case scored 1.00 in both arms, so it is a genuine
# NO_GAP, which the default strict gate fails with exit 4 — a correct verdict
# that would mask the thing under test.
set +e
out=$(/bin/bash "$SCRIPT" --classify "$REAL" --gate report 2>/dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'NO_GAP'; then
  ok "a real captured aggregate classifies without error"
else
  bad "a real captured aggregate classifies without error (got rc=$rc: ${out:-<empty>})"
fi
```

- [ ] **Step 5: Run the suite**

Run: `/bin/bash .github/tests/test-run-evals.sh 2>&1 | tail -3`
Expected: `63 passed, 0 failed`

- [ ] **Step 6: Commit**

```bash
jj describe -m "test(evals): commit a real captured aggregate as ground truth (#102)"
jj new
```

---

### Task 2: Require per-run turn detail

**Files:**
- Modify: `.github/scripts/run-evals.sh` — insert after the delta/score tripwire (currently ends at the `exit 5` / `fi` around line 103), before the `# The 0.5 threshold` comment
- Modify: `.github/tests/fixtures/evals/{boundary,boundaryexact,broken,discriminating,mixed,nogap,partialgap,regression}.json`
- Modify: `.github/tests/test-run-evals.sh`

**Interfaces:**
- Consumes: `$REAL` from Task 1.
- Produces: exit 5 plus a diagnostic containing the literal string `per-run turn detail` and, per bad case, a line `  case #<index> (<name>): <fields>`.

Leave the existing delta/score tripwire **unmodified**. Its three fixtures (`nulldelta`, `stringdelta`, `driftedscores`) carry no `runs` and must keep reaching it first.

- [ ] **Step 1: Write the failing assertions**

Add to `.github/tests/test-run-evals.sh`, immediately after the `driftedscores` assertion block:

```bash
# Per-run turn detail is required (#102 Gap B). Absence is drift, NOT permission
# to skip the dead-arm check — treating a missing field as "no dead arms found"
# is how a tripwire fails open.
#
# Anchored on wording unique to THIS tripwire. The delta/score tripwire above
# also exits 5, and an assertion on rc alone cannot tell them apart — that
# aliasing is what made the delta/score invariant untestable in #102's first
# attempt and shipped a string-typed delta gating green.
NORUNS=$(new_tmp)
jq -nc '{schema_version:"1.0",partial:false,cases:[{name:"no-detail",score:1,score_without:0,delta:1}]}' \
  > "$NORUNS/norundetail.json"
set +e
err=$(/bin/bash "$SCRIPT" --classify "$NORUNS/norundetail.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'per-run turn detail'; then
  ok "missing per-run turn detail trips its own tripwire (exit 5)"
else
  bad "missing per-run turn detail trips its own tripwire (exit 5) (got rc=$rc: ${err:-<empty>})"
fi

# The diagnostic must locate the case. Index, not name: .name may be absent,
# null or empty, and an operator with 16 cases cannot act on "some case".
BADRUNS=$(new_tmp)
jq -nc '{schema_version:"1.0",partial:false,cases:[
  {name:"fine",score:1,score_without:0,delta:1,runs:[{turns:3}],runs_without:[{turns:2}]},
  {score:1,score_without:0,delta:1,runs:[{trace_path:"x"}],runs_without:[{turns:2}]}]}' \
  > "$BADRUNS/badruns.json"
set +e
err=$(/bin/bash "$SCRIPT" --classify "$BADRUNS/badruns.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'case #1' \
   && printf '%s' "$err" | grep -q 'turns'; then
  ok "the turn-detail diagnostic names the case by index and the field"
else
  bad "the turn-detail diagnostic names the case by index and the field (got rc=$rc: ${err:-<empty>})"
fi
```

- [ ] **Step 2: Anchor the three pre-existing drift assertions on their own wording**

In the same file, change the three assertions that currently test `rc -eq 5` alone. For each, capture stderr and require the delta/score message. Replace the `nulldelta` block with:

```bash
set +e
err=$(/bin/bash "$SCRIPT" --classify "$FIX/nulldelta.json" 2>&1 >/dev/null)
rc=$?
set -e
if [ "$rc" -eq 5 ] && printf '%s' "$err" | grep -q 'delta/score'; then
  ok "null delta trips the tripwire (exit 5)"
else
  bad "null delta trips the tripwire (exit 5) (got rc=$rc: ${err:-<empty>})"
fi
```

Apply the identical shape to the `stringdelta` and `driftedscores` blocks, keeping their existing `ok`/`bad` message text and, for `driftedscores`, its `--gate strict` argument.

- [ ] **Step 3: Run to verify the new assertions fail**

Run: `/bin/bash .github/tests/test-run-evals.sh 2>&1 | grep -E '^FAIL|passed,'`
Expected: the two new assertions FAIL (`got rc=0`). The three re-anchored ones still PASS — the delta/score message already contains `delta/score`.

- [ ] **Step 4: Add the tripwire**

In `.github/scripts/run-evals.sh`, insert immediately after the existing delta/score tripwire's closing `fi`:

```bash
  # Per-run turn detail must be present and numeric (#102 Gap B). The dead-arm
  # verdict below reads .cases[].runs[].turns; a missing field must never read
  # as "no dead arms found".
  #
  # SEPARATE from the delta/score tripwire above, deliberately. Folding them
  # gives both invariants one message, and an assertion could then no longer
  # tell which fired — that aliasing is what let a string-typed delta gate
  # green while the suite stayed green too.
  #
  # `turns`, not `num_turns`. The aggregate's per-run keys are
  # cost_usd, duration_seconds, error, graders, judge_cost_usd, score,
  # started_at, trace_path, turns — verified against the captured fixture in
  # fixtures/evals/real/. `num_turns` is the CLI's per-run RESULT MESSAGE
  # field; keying on it aborts every real sweep after full spend.
  #
  # An EMPTY runs array is not drift — it is an arm that ran nothing, which the
  # DEAD_ARM verdict reports per case rather than aborting the whole file.
  if [ "$(jq -r '[.cases[]?
                  | select((.runs         | type) != "array"
                        or (.runs_without | type) != "array"
                        or ([(.runs + .runs_without)[] | .turns | numbers] | length)
                           != ((.runs + .runs_without) | length))] | length' "$file")" != "0" ]; then
    printf 'ERROR: a case is missing per-run turn detail — result schema drift.\n' >&2
    # Located by INDEX. `.name` may be absent, null or empty, and a join over
    # names yields "" for exactly the case a reader most needs to find.
    jq -r '.cases | to_entries[]
           | select((.value.runs         | type) != "array"
                 or (.value.runs_without | type) != "array"
                 or ([(.value.runs + .value.runs_without)[] | .turns | numbers] | length)
                    != ((.value.runs + .value.runs_without) | length))
           | "  case #\(.key) (\(.value.name // "<unnamed>")): expected numeric .runs[].turns"' \
      "$file" >&2
    printf 'Expected .cases[].runs[] and .runs_without[], each entry carrying a\n' >&2
    printf 'numeric "turns". See .github/tests/fixtures/evals/real/README.md.\n' >&2
    exit 5
  fi
```

- [ ] **Step 5: Run — new assertions pass, eight old ones now fail**

Run: `/bin/bash .github/tests/test-run-evals.sh 2>&1 | grep -E '^FAIL|passed,'`
Expected: the two new assertions PASS; assertions using `boundary`, `boundaryexact`, `broken`, `discriminating`, `mixed`, `nogap`, `partialgap`, `regression` now FAIL. This is correct — those fixtures predate the requirement.

- [ ] **Step 6: Backfill the eight synthetic fixtures**

```bash
cd .github/tests/fixtures/evals
for f in boundary boundaryexact broken discriminating mixed nogap partialgap regression; do
  tmp=$(mktemp)
  jq '.cases |= map(. + {runs:[{turns:3}], runs_without:[{turns:2}]})' "$f.json" > "$tmp" && mv "$tmp" "$f.json"
done
```

Turn counts are illustrative; the only property under test is that they are non-zero, i.e. the arm executed. Do **not** touch `nulldelta`, `stringdelta`, `driftedscores` (they must keep tripping the delta/score check first), nor `nocases`, `partial`, `partialnocases` (they abort earlier still).

The suite also embeds three result payloads inline, in the `claude` stub near the bottom of `test-run-evals.sh`. They drive the live-path assertions and need the same backfill, or "live path survives CLI exit 1" and "stdout is pure TSV" stay red:

```bash
python3 - <<'PY'
p='.github/tests/test-run-evals.sh'
s=open(p).read()
for old,new in [
 ('{"name":"c","score":0.5,"score_without":0,"delta":0.5}',
  '{"name":"c","score":0.5,"score_without":0,"delta":0.5,"runs":[{"turns":3}],"runs_without":[{"turns":2}]}'),
 ('{"name":"c","score":1,"score_without":0,"delta":1}',
  '{"name":"c","score":1,"score_without":0,"delta":1,"runs":[{"turns":3}],"runs_without":[{"turns":2}]}'),
]:
    assert old in s
    s=s.replace(old,new)
open(p,'w').write(s)
PY
```

Step 5 will show ~18 failing assertions, not 8: several fixtures serve more than one assertion, and the inline payloads account for two more.

- [ ] **Step 7: Run the suite**

Run: `/bin/bash .github/tests/test-run-evals.sh 2>&1 | tail -3`
Expected: `65 passed, 0 failed`

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(evals): require numeric .runs[].turns in classify() (#102 Gap B)"
jj new
```

---

### Task 3: DEAD_ARM verdict and gate

**Files:**
- Modify: `.github/scripts/run-evals.sh` — the TSV `jq` program and both gate `jq` expressions
- Create: `.github/tests/fixtures/evals/{deadarm,deadarmnested,deadarmempty}.json`
- Modify: `.github/tests/test-run-evals.sh`

**Interfaces:**
- Consumes: the `turns` guarantee from Task 2.
- Produces: TSV column 5 values `DEAD_ARM(with)`, `DEAD_ARM(without)`, `DEAD_ARM(both)`; gate exit 4 when any case is dead, in both `strict` and `report`.

- [ ] **Step 1: Create the dead-arm fixtures**

```bash
cd .github/tests/fixtures/evals
# The measured failure: a without-arm that never ran still banks 0.50 from
# vacuously-passing negative graders, manufacturing Delta +0.50. Deliberately
# UNNAMED — a name-keyed guard skips exactly this case.
jq -nc '{schema_version:"1.0",partial:false,cost_usd:0.1,cases:[{score:1,score_without:0.5,delta:0.5,runs:[{turns:2}],runs_without:[{turns:0},{turns:0}]}]}' > deadarm.json
# A nested counter must not mask a dead arm.
jq -nc '{schema_version:"1.0",partial:false,cost_usd:0.1,cases:[{name:"nested",score:1,score_without:0.5,delta:0.5,runs:[{turns:2}],runs_without:[{turns:0,steps:[{turns:9}]}]}]}' > deadarmnested.json
# An arm with no runs at all is dead, not drift.
jq -nc '{schema_version:"1.0",partial:false,cost_usd:0.1,cases:[{name:"empty",score:1,score_without:0.5,delta:0.5,runs:[],runs_without:[{turns:3}]}]}' > deadarmempty.json
```

- [ ] **Step 2: Write the failing assertions**

Add to `.github/tests/test-run-evals.sh` after the Task 2 assertions:

```bash
# A 0-turn arm banks free score (#102 Gap B). MEASURED, docs/eval-triage-2026-07.md
# §2.2-2.3: a prompt the CLI could not resolve returned num_turns 0 with
# subtype "success" and is_error false. Every negative grader (tool_used at
# min 0/max 0) then passes VACUOUSLY — the arm did not call the forbidden tool
# because it did nothing at all — so the arm scored 0.50 and manufactured a
# Delta +0.50 DISCRIMINATING, above the ship threshold. The both-arms-zero
# BROKEN detector cannot see it: the arm is not at zero, it is at half marks
# for doing nothing.
#
# A per-case VERDICT, not a whole-file abort. .partial aborts because it is a
# whole-run property; a dead arm belongs to one case, and aborting would
# discard the other 15 verdicts of a paid 16-case sweep.
got=$(verdict_of "$FIX/deadarm.json" || true)
if [ "$got" = "DEAD_ARM(without)" ]; then
  ok "a 0-turn without-arm is DEAD_ARM(without)"
else
  bad "a 0-turn without-arm is DEAD_ARM(without) (got: ${got:-<empty>})"
fi

# The fixture above has NO .name on purpose: a guard keyed on .name joins to ""
# and silently skips the case, printing the manufactured verdict at rc 0.
if [ -n "$got" ] && [ "$got" != "DISCRIMINATING" ]; then
  ok "an unnamed dead case is not silently skipped"
else
  bad "an unnamed dead case is not silently skipped (got: ${got:-<empty>})"
fi

got=$(verdict_of "$FIX/deadarmnested.json" || true)
if [ "$got" = "DEAD_ARM(without)" ]; then
  ok "a nested turn counter does not mask a dead arm"
else
  bad "a nested turn counter does not mask a dead arm (got: ${got:-<empty>})"
fi

got=$(verdict_of "$FIX/deadarmempty.json" || true)
if [ "$got" = "DEAD_ARM(with)" ]; then
  ok "an arm with no runs at all is DEAD_ARM(with)"
else
  bad "an arm with no runs at all is DEAD_ARM(with) (got: ${got:-<empty>})"
fi

# One dead case must not suppress the others. The whole point of a verdict row
# over an abort: a 16-case sweep is already paid for.
TWO=$(new_tmp)
jq -nc '{schema_version:"1.0",partial:false,cases:[
  {name:"good",score:1,score_without:0,delta:1,runs:[{turns:5}],runs_without:[{turns:4}]},
  {name:"bad", score:1,score_without:0.5,delta:0.5,runs:[{turns:2}],runs_without:[{turns:0}]}]}' \
  > "$TWO/two.json"
if [ "$(row_count "$TWO/two.json")" = "2" ] \
   && [ "$(verdict_at "$TWO/two.json" 1)" = "DISCRIMINATING" ]; then
  ok "a dead case does not suppress the other verdict rows"
else
  bad "a dead case does not suppress the other verdict rows (rows=$(row_count "$TWO/two.json"))"
fi

# The gate must agree with the table it printed, in BOTH modes. A dead arm is
# never a "finding" — report mode tolerates NO_GAP and PARTIAL because they are
# measurements; a dead arm is the absence of one.
for mode in strict report; do
  set +e
  /bin/bash "$SCRIPT" --classify "$FIX/deadarm.json" --gate "$mode" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 4 ]; then
    ok "the $mode gate fails a dead arm (exit 4)"
  else
    bad "the $mode gate fails a dead arm (exit 4) (got rc=$rc)"
  fi
done
```

- [ ] **Step 3: Run to verify they fail**

Run: `/bin/bash .github/tests/test-run-evals.sh 2>&1 | grep -E '^FAIL|passed,'`
Expected: seven new assertions FAIL — verdicts come back `DISCRIMINATING` and both gates return 0.

- [ ] **Step 4: Add `dead()` to the TSV program**

Replace the TSV `jq` block in `classify()` with:

```bash
  jq -r '
    def eps: 1e-9;
    # An arm is dead when it ran nothing, or when its BEST run took no turns.
    # `.turns` at the FIXED path — a recursive `..` search lets any nested
    # counter the CLI adds mask a genuinely 0-turn arm via max.
    def dead(a): (a | length) == 0 or ([a[] | .turns] | max) == 0;
    .cases[]?
    | [ .name,
        (.score          | tostring),
        (.score_without  | tostring),
        (.delta          | tostring),
        # DEAD_ARM outranks BROKEN: both-arms-zero and both-arms-dead can
        # co-occur, and "the arms never ran" is the actionable diagnosis.
        ( if   dead(.runs) and dead(.runs_without) then "DEAD_ARM(both)"
          elif dead(.runs)                         then "DEAD_ARM(with)"
          elif dead(.runs_without)                 then "DEAD_ARM(without)"
          elif (.score == 0 and .score_without == 0) then "BROKEN"
          elif .delta <  -eps         then "REGRESSION"
          elif .delta <   eps         then "NO_GAP"
          elif .delta <  (0.5 - eps)  then "PARTIAL"
          else                             "DISCRIMINATING"
          end )
      ] | @tsv
  ' "$file"
```

- [ ] **Step 5: Add `dead()` to both gate expressions**

Replace the two `bad_count=` assignments with:

```bash
  if [ "$GATE" = "strict" ]; then
    bad_count=$(jq -r 'def dead(a): (a | length) == 0 or ([a[] | .turns] | max) == 0;
      [.cases[]? | select(dead(.runs) or dead(.runs_without)
                       or (.score == 0 and .score_without == 0)
                       or .delta < (0.5 - 1e-9))] | length' "$file")
  else
    bad_count=$(jq -r 'def dead(a): (a | length) == 0 or ([a[] | .turns] | max) == 0;
      [.cases[]? | select(dead(.runs) or dead(.runs_without)
                       or (.score == 0 and .score_without == 0)
                       or .delta < -1e-9)] | length' "$file")
  fi
```

- [ ] **Step 6: Run the suite**

Run: `/bin/bash .github/tests/test-run-evals.sh 2>&1 | tail -3`
Expected: `72 passed, 0 failed`

- [ ] **Step 7: Confirm the real capture still classifies**

Run: `/bin/bash .github/scripts/run-evals.sh --classify .github/tests/fixtures/evals/real/hook-allows-jj-git-and-gh-2026-07-26.json --gate report; echo "rc=$?"`
Expected: one row ending `NO_GAP`, `rc=0`. (`--gate report` is required — the captured case is a genuine NO_GAP, which strict correctly fails with exit 4.)

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(evals): report a 0-turn ablation arm as DEAD_ARM (#102 Gap B)"
jj new
```

---

### Task 4: Mutation matrix, docs, and ship

**Files:**
- Modify: `docs/eval-triage-2026-07.md` §7
- Test: mutation runs against `.github/scripts/run-evals.sh` (restored after each)

**Interfaces:**
- Consumes: everything from Tasks 1–3.

- [ ] **Step 1: Snapshot the script**

```bash
cp .github/scripts/run-evals.sh /tmp/evals-good.sh
```

- [ ] **Step 2: Mutation — wrong field name**

Change every `.turns` in `run-evals.sh` to `.num_turns`, run the suite, restore.

```bash
sed -i '' 's/\.turns/.num_turns/g' .github/scripts/run-evals.sh
/bin/bash .github/tests/test-run-evals.sh 2>&1 | grep -E '^FAIL|passed,'
cp /tmp/evals-good.sh .github/scripts/run-evals.sh
```

Expected: **"a real captured aggregate classifies without error" FAILS.** This is the assertion that would have caught #102's first attempt. If it does not fail, the real fixture is not load-bearing and Task 1 is worthless — stop and fix.

- [ ] **Step 3: Mutation — recursive descent**

Replace the `dead()` definition with a recursive-descent variant, run, restore.

```bash
python3 - <<'PY'
p='.github/scripts/run-evals.sh'
s=open(p).read()
s=s.replace('def dead(a): (a | length) == 0 or ([a[] | .turns] | max) == 0;',
            'def dead(a): (a | length) == 0 or ([a[] | [.. | objects | .turns? | numbers] | max] | max) == 0;')
open(p,'w').write(s)
PY
/bin/bash .github/tests/test-run-evals.sh 2>&1 | grep -E '^FAIL|passed,'
cp /tmp/evals-good.sh .github/scripts/run-evals.sh
```

Expected: **"a nested turn counter does not mask a dead arm" FAILS**, and nothing else does.

- [ ] **Step 4: Mutation — name-keyed identification**

Confirm the unnamed-case assertion is load-bearing by making `dead()` consult `.name`:

```bash
python3 - <<'PY'
p='.github/scripts/run-evals.sh'
s=open(p).read()
s=s.replace('def dead(a): (a | length) == 0 or ([a[] | .turns] | max) == 0;',
            'def dead(a): ((.name // "") != "") and ((a | length) == 0 or ([a[] | .turns] | max) == 0);')
open(p,'w').write(s)
PY
/bin/bash .github/tests/test-run-evals.sh 2>&1 | grep -E '^FAIL|passed,'
cp /tmp/evals-good.sh .github/scripts/run-evals.sh
```

Expected: **"a 0-turn without-arm is DEAD_ARM(without)" and "an unnamed dead case is not silently skipped" FAIL.**

- [ ] **Step 5: Mutation — delete the delta/score tripwire**

This is the F4 regression check: the invariant must be independently covered again.

```bash
python3 - <<'PY'
p='.github/scripts/run-evals.sh'
s=open(p).read()
i=s.index("  # Tripwire: any missing OR non-numeric delta")
j=s.index("  # Per-run turn detail must be present", i)
open(p,'w').write(s[:i]+s[j:])
PY
/bin/bash .github/tests/test-run-evals.sh 2>&1 | grep -E '^FAIL|passed,'
cp /tmp/evals-good.sh .github/scripts/run-evals.sh
```

Expected: **the `nulldelta`, `stringdelta` and `driftedscores` assertions FAIL.** If the suite stays green, the delta/score invariant is still untested and the re-anchoring in Task 2 Step 2 did not take — stop and fix.

- [ ] **Step 6: Confirm the script is restored, then run the full gate**

```bash
cmp -s /tmp/evals-good.sh .github/scripts/run-evals.sh && echo "restored" || echo "NOT RESTORED — stop"
export JJ_USER=CI JJ_EMAIL=ci@example.invalid
find plugins .github -path '*/tests/test-*.sh' | sort | while IFS= read -r t; do
  if out=$(/bin/bash "$t" 2>&1); then
    printf 'PASS %-58s %s\n' "$t" "$(printf '%s' "$out" | grep -oE '[0-9]+ passed' | tail -1)"
  else printf 'FAIL %s\n' "$t"; fi
done
```

Expected: 17/17 suites pass.

- [ ] **Step 7: Update the triage doc**

In `docs/eval-triage-2026-07.md` §7, change the opening line to state that all three gaps are now closed, and replace the Gap B "Still open" block with a closure note recording: the field is `turns` at `.cases[].runs[]`; a dead arm is a per-case `DEAD_ARM` verdict failing the gate in both modes, not a whole-file abort; and that a partially-dead arm (only some runs at zero) is deliberately not covered, because there is no measurement of legitimate run-to-run variance and a tripwire tuned on a guess would abort real sweeps.

- [ ] **Step 8: Commit and open the PR**

```bash
jj describe -m "fix(evals): detect an ablation arm that executed zero turns (#102 Gap B)"
jj bookmark create fix-102-dead-arm -r @
jj git push --bookmark fix-102-dead-arm
gh pr create --base main --head fix-102-dead-arm --title "fix(evals): detect an ablation arm that executed zero turns (#102 Gap B)" --body-file <path to body written with Write>
```

No plugin files are touched, so no version bump applies — confirm with:

```bash
CHANGED_FILES="$(jj diff --from 'trunk()' --to @ --name-only)" BASE_DIR=<base tree> /bin/bash .github/scripts/require-version-bump.sh
```

---

## Self-Review

**Spec coverage.** Real fixture committed verbatim with provenance (Task 1). `turns` at the fixed path (Task 2, Global Constraints). Dead when every run is at zero, empty arm counts as dead (Task 3 Step 4). Index-based identification (Task 2 Step 4 diagnostic; Task 3 uses an unnamed fixture). `DEAD_ARM(with|without|both)` failing both gate modes (Task 3 Steps 4–5). No new exit code, no whole-file abort (Task 3 Step 2's two-case assertion). Eight synthetic fixtures backfilled (Task 2 Step 6). Three drift assertions re-anchored on wording (Task 2 Step 2) and mutation-verified (Task 4 Step 5). All four required mutations present (Task 4 Steps 2–5).

**Deviation, flagged.** The runs/turns check is a *separate* tripwire rather than folded into the delta/score one — folding gives both invariants a shared message and makes them mutually untestable, which is the exact defect Task 4 Step 5 exists to catch.

**Assertion-count arithmetic.** Baseline 62 → 63 (Task 1) → 65 (Task 2: +2 new; the three re-anchored ones are edits, not additions) → 72 (Task 3: +7).

**Known non-goal.** A partially-dead arm — some runs at zero, some not — still inflates the mean and is not detected. Deliberate: no measurement of legitimate variance exists, and a threshold guessed now would abort real sweeps. Revisit with tranche-2 data.
