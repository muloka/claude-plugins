# Code Review Plugin (jj)

Automated code review for pull requests using multiple specialized agents with confidence-based scoring to filter false positives. Designed for jj (Jujutsu) repositories.

## Overview

The Code Review Plugin automates pull request review by launching multiple agents in parallel to independently audit changes from different perspectives. It uses confidence scoring to filter out false positives, ensuring only high-quality, actionable feedback is posted.

This is the jj (Jujutsu) edition. It works with both colocated repos (`.jj/` + `.git/`) and non-colocated repos.

## Setup

### Colocated repos (`.jj/` + `.git/`)

Everything works out of the box. The `gh` CLI can access Git state directly.

### Non-colocated repos (`.jj/` only)

The `gh` CLI needs access to Git state. Either:

1. **Set `GIT_DIR`** before running:
   ```bash
   export GIT_DIR=.jj/repo/store/git
   ```

2. **Or run `jj git export`** before using `/code-review` to sync jj state to the backing Git repo.

## Commands

### `/code-review`

Performs automated code review on a pull request using multiple specialized agents.

**What it does:**
1. Checks if review is needed (skips closed, draft, trivial, or already-reviewed PRs)
2. Gathers relevant CLAUDE.md guideline files from the repository
3. Summarizes the pull request changes
4. Launches 5 parallel agents to independently review:
   - **Agent #1**: Audit for CLAUDE.md compliance
   - **Agent #2**: Scan for obvious bugs in changes
   - **Agent #3**: Analyze file annotation history for context-based issues
   - **Agent #4**: Check previous PR comments for recurring patterns
   - **Agent #5**: Verify compliance with code comments
5. Scores each issue 0-100 for confidence level
6. Filters out issues below 80 confidence threshold
7. Posts review comment with high-confidence issues only

**Usage:**
```bash
/code-review
```

**Features:**
- Multiple independent agents for comprehensive review
- Confidence-based scoring reduces false positives (threshold: 80)
- CLAUDE.md compliance checking with explicit guideline verification
- Bug detection focused on changes (not pre-existing issues)
- Historical context analysis via file annotation history
- Automatic skipping of closed, draft, or already-reviewed PRs
- Links directly to code with full SHA and line ranges

## Installation

```bash
claude plugins add ./plugins/code-review-jj
```

## Requirements

- jj (Jujutsu) repository
- GitHub CLI (`gh`) installed and authenticated
- For non-colocated repos: `GIT_DIR` setup or `jj git export` workflow
- CLAUDE.md files (optional but recommended for guideline checking)

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
