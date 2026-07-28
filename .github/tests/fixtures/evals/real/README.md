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

The per-run key set, as captured:

    cost_usd, duration_seconds, error, graders, judge_cost_usd,
    score, started_at, trace_path, turns
