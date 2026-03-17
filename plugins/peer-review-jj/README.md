# peer-review-jj

Unified change review for jj repos. Generalist-first architecture with emergent specialists.

## Usage

```
/peer-review                          # review current change (@)
/peer-review <revision>               # review specific change
/peer-review --deep errors types      # generalist + specialist dispatch
/peer-review --track                  # enable progress tracking (duplicate+squash)
/peer-review --post                   # post findings to GitHub PR
/peer-review --json                   # raw structured output
/peer-review --discard                # abandon review state after completion
```

## Architecture

Two-phase pipeline:

1. **Requesting** — assess change size, partition files, dispatch generalist reviewers in parallel
2. **Receiving** — aggregate findings, deduplicate, reconcile verdicts, manage specialist lifecycle

Generalists scale with change size (1 per ~300 lines). Specialists emerge from repeated review patterns (3+ distinct patterns triggers a creation prompt).

## Components

- `commands/peer-review.md` — single entry point
- `skills/requesting-change-review.md` — phase 1: dispatch
- `skills/receiving-change-review.md` — phase 2: aggregation
- `agents/change-reviewer.md` — generalist reviewer agent
- `scripts/block-raw-git.sh` — hook: prevent raw git commands
- `scripts/block-review-markers.sh` — hook: prevent review markers in commits

## Replaces

- `code-review-jj` — GitHub posting, confidence scoring, false positive list
- `pr-review-toolkit-jj` — specialist agents (now reference material for emergence)
- `feature-dev-jj` — unused (superpowers brainstorming covers the workflow)

## Design

See [docs/peer-review-jj/2026-03-16-peer-review-jj-design.md](../../docs/peer-review-jj/2026-03-16-peer-review-jj-design.md).

## Note

This is a jj-only plugin. No raw git commands — use jj equivalents.
