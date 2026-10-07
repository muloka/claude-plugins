# Wave Reviewer Prompt Template

Use this template when dispatching peer review agents during the REVIEW phase.

**Purpose:** Verify spec compliance AND code quality in a single pass. The reviewer reads the task brief files as ground truth, eliminating hallucinations about intent — and the briefs travel as file paths, never as pasted text in the orchestrator's context.

**Dispatch context:** Wave reviewers run in the orchestrator's context (no `isolation: "worktree"`). They are read-only, using jj revset commands to inspect changes by change ID. All reviewers for the wave run in parallel and cannot conflict.

**Agent type:** `general-purpose`, not peer-review-jj's `change-reviewer`. This
template is a complete review contract (format, severities, scope, the
plan-mandated rule), and change-reviewer's own defaults compete with it:
its do-not-report list excludes "intentional changes", and on a fixture
with a defect the brief itself mandated, change-reviewer reported it as a
non-blocking `suggestion` in 2 of 4 runs, against `important` in 4 of 4 as
general-purpose (both caught the other planted findings every time). It also
drops a dependency: kaisen no longer needs peer-review-jj installed.

## Template

```
Agent tool:
  subagent_type: "general-purpose"
  model: <per the skill's Model Selection — sonnet floor; opus for risky or
         final waves. Always explicit; never omitted>
  description: "Wave N review: <files summary>"
  prompt: |
    You are reviewing code from a parallel execution wave. You have the original
    task specs — use them as ground truth for what was requested.

    ## What Was Requested (Wave [WAVE_NUMBER])

    Read the task briefs first — they are the requirements and your ground
    truth for what was asked:

    [BRIEF_FILES]

    ## What the Implementers Claim They Built

    Read the implementer reports:

    [REPORT_FILES]

    Treat the reports as unverified claims — verify them against the code,
    not the other way around.

    ## What Was Built

    Files to review:

    [FILES_TO_REVIEW]

    ## How to Read the Code

    This is a jj repository. The changes live in these change IDs: [CHANGE_IDS]

    jj diff -r [CHANGE_ID]                        # see what changed
    jj file show -r [CHANGE_ID] [path]            # read a file at that revision
    jj log -r [CHANGE_ID] --stat                  # summary of files touched

    Do NOT limit yourself to the diff. Read full files when context matters
    for understanding whether the implementation is correct.

    CRITICAL: You MUST NOT use ANY raw git commands. Always use jj equivalents.

    This review is read-only: do not edit, create or delete files. Every
    finding goes in your report.

    ## Your Job

    The wave's test gate has already run — don't re-verify test values.
    If the orchestrator told you this wave has no test surface, then no
    automated check has validated this work at all; review accordingly.
    Focus on what tests CAN'T catch.

    1. **Spec compliance:** does the code match the spec? Missing/extra/wrong?
    2. **Quality:** correctness, naming, patterns, edge cases, idiomatic code
    3. **Cross-module:** are imports and APIs used correctly across wave files?

    ## Report Format

    Return a JSON array of findings:

    ```json
    [
      {
        "file": "path/to/file.rs",
        "line": 42,
        "severity": "critical|important|suggestion|cannot-verify",
        "category": "spec|quality|cross-module",
        "finding": "description of the issue"
      }
    ]
    ```

    If no issues found, return an empty array: `[]`

    Severity guide:
    - **critical**: wrong behavior, missing requirement, security issue
    - **important**: the task can't be merged until fixed — incorrect or
      fragile behavior, a missed requirement, verbatim duplication of a
      logic block, swallowed errors, tests that assert nothing
    - **suggestion**: style preference, broader-coverage wishes, polish —
      don't block on these
    - **cannot-verify**: a requirement you can't verify from this wave's
      changes alone (it lives in unchanged code or spans tasks). Say in the
      finding what the orchestrator should check. Report it alongside your
      other findings — don't widen your search to chase it

    Calibration: not everything is critical. If the brief itself mandates
    something this rubric calls a defect, that IS a finding — report it as
    important with "plan-mandated" in the text. The plan's authorship does
    not grade its own work; the human decides.
```

## Placeholders

- `[WAVE_NUMBER]` — the current wave number
- `[BRIEF_FILES]` — paths to the wave's task brief files
  (`<artifacts>/task-N-brief.md`), one per line — paths, never pasted text
- `[REPORT_FILES]` — paths to the implementer report files
  (`<artifacts>/task-N-report.md`), one per line
- `[FILES_TO_REVIEW]` — list of file paths assigned to this reviewer
- `[CHANGE_IDS]` — the jj change IDs from the implementers (may be multiple if reviewer covers multiple tasks)
