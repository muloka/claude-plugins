# PR Review Toolkit (jj)

A comprehensive collection of specialized agents for thorough pull request review, covering code comments, test coverage, error handling, type design, code quality, and code simplification. Designed for jj (Jujutsu) repositories.

## Overview

This plugin bundles 6 expert review agents that each focus on a specific aspect of code quality. Use them individually for targeted reviews or together for comprehensive PR analysis.

This is the jj (Jujutsu) edition. Agents use `jj diff` instead of `git diff` for identifying changes in the working copy.

## Setup

### Colocated repos (`.jj/` + `.git/`)

Everything works out of the box.

### Non-colocated repos (`.jj/` only)

If any agent needs `gh` CLI access, either:
- Set `GIT_DIR=.jj/repo/store/git`
- Or run `jj git export` before using PR-related features

## Agents

### 1. comment-analyzer
**Focus**: Code comment accuracy and maintainability

### 2. pr-test-analyzer
**Focus**: Test coverage quality and completeness

### 3. silent-failure-hunter
**Focus**: Error handling and silent failures

### 4. type-design-analyzer
**Focus**: Type design quality and invariants

### 5. code-reviewer
**Focus**: General code review for project guidelines

### 6. code-simplifier
**Focus**: Code simplification and refactoring

## Usage Patterns

### Individual Agent Usage

Simply ask questions that match an agent's focus area, and Claude will automatically trigger the appropriate agent:

```
"Can you check if the tests cover all edge cases?"
→ Triggers pr-test-analyzer

"Review the error handling in the API client"
→ Triggers silent-failure-hunter

"I've added documentation - is it accurate?"
→ Triggers comment-analyzer
```

### Comprehensive PR Review

```
/pr-review-toolkit-jj:review-pr all
```

## Installation

```bash
claude plugins add ./plugins/pr-review-toolkit-jj
```

## Best Practices

- **Before committing**: Run code-reviewer for general quality
- **Before creating PR**: Run all applicable agents
- **After passing review**: Run code-simplifier to polish
- **Focus on changes**: Agents analyze `jj diff` by default

## Requirements

- jj (Jujutsu) repository
- For PR features: GitHub CLI (`gh`) installed and authenticated
- CLAUDE.md files (optional but recommended)

## Author

muloka (muloka@users.noreply.github.com)

## Version

1.0.0
