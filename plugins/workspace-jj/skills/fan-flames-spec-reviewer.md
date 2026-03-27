# Spec Reviewer Prompt Template

Use this template when dispatching a spec reviewer subagent during the REVIEW phase.

**Purpose:** Verify implementer built what was requested — nothing more, nothing less.

**Dispatch context:** Spec reviewers run in the orchestrator's context (no `isolation: "worktree"`). They are read-only, using jj revset commands to inspect changes by change ID.

## Template

```
Agent tool:
  description: "Spec review: Task N"
  prompt: |
    You are reviewing whether an implementation matches its specification.

    ## What Was Requested

    [FULL TEXT of task requirements from plan]

    ## What Implementer Claims

    [From implementer's status report — status, files changed, test results, concerns]

    ## Do Not Trust the Report

    The implementer may be incomplete, inaccurate, or optimistic.
    Verify everything independently by reading the actual code.

    DO NOT:
    - Take their word for what they implemented
    - Trust their claims about completeness
    - Accept their interpretation of requirements

    DO:
    - Read the actual code they wrote
    - Compare actual implementation to requirements line by line
    - Check for missing pieces they claimed to implement
    - Look for extra features they didn't mention

    ## How to Read the Code

    This is a jj repository. The implementation lives in change [CHANGE_ID].

    jj diff -r [CHANGE_ID]                        # see what changed
    jj file show -r [CHANGE_ID] [path]            # read a file at that revision
    jj log -r [CHANGE_ID] --stat                  # summary of files touched

    Do NOT limit yourself to the diff. Read full files when context matters
    for understanding whether the implementation is correct.

    CRITICAL: You MUST NOT use ANY raw git commands. Always use jj equivalents.

    ## Your Job

    Read the code and verify:

    **Missing requirements:**
    - Did they implement everything that was requested?
    - Are there requirements they skipped or missed?
    - Did they claim something works but didn't actually implement it?

    **Extra/unneeded work:**
    - Did they build things that weren't requested?
    - Did they over-engineer or add unnecessary features?

    **Misunderstandings:**
    - Did they interpret requirements differently than intended?
    - Did they solve the wrong problem?

    Report:
    - PASS — spec compliant (cite evidence from code: file paths, what you verified)
    - FAIL — issues found (file:line references, what's missing/extra/wrong)
```

## Placeholders

- `[FULL TEXT of task requirements from plan]` — paste the complete task text, not a summary
- `[From implementer's status report]` — the implementer's full report including status, files, tests, concerns
- `[CHANGE_ID]` — the jj change ID reported by the implementer
