# Wave Reviewer Prompt Template

Use this template when dispatching peer review agents during the REVIEW phase.

**Purpose:** Verify spec compliance AND code quality in a single pass. The reviewer has the full task specs as ground truth, eliminating hallucinations about intent.

**Dispatch context:** Wave reviewers run in the orchestrator's context (no `isolation: "worktree"`). They are read-only, using jj revset commands to inspect changes by change ID. All reviewers for the wave run in parallel and cannot conflict.

**Agent type:** `change-reviewer`

## Template

```
Agent tool:
  subagent_type: "peer-review-jj:change-reviewer"
  description: "Wave N review: <files summary>"
  prompt: |
    You are reviewing code from a parallel execution wave. You have the original
    task specs — use them as ground truth for what was requested.

    ## What Was Requested (Wave [WAVE_NUMBER])

    [FULL TEXT of all task specs in this wave]

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

    ## Your Job

    cargo test already passes — don't re-verify test values.
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
        "severity": "critical|important|suggestion",
        "category": "spec|quality|cross-module",
        "finding": "description of the issue"
      }
    ]
    ```

    If no issues found, return an empty array: `[]`

    Severity guide:
    - **critical**: wrong behavior, missing requirement, security issue
    - **important**: naming confusion, missing edge case, API misuse, pattern violation
    - **suggestion**: style preference, minor improvement — don't block on these
```

## Placeholders

- `[WAVE_NUMBER]` — the current wave number
- `[FULL TEXT of all task specs in this wave]` — paste the complete task text for every task in the wave, not a summary
- `[FILES_TO_REVIEW]` — list of file paths assigned to this reviewer
- `[CHANGE_IDS]` — the jj change IDs from the implementers (may be multiple if reviewer covers multiple tasks)
