# Feature Development Plugin (jj)

A comprehensive, structured workflow for feature development with specialized agents for codebase exploration, architecture design, and quality review. Designed for jj (Jujutsu) repositories.

## Overview

The Feature Development Plugin provides a systematic 7-phase approach to building new features. Instead of jumping straight into code, it guides you through understanding the codebase, asking clarifying questions, designing architecture, and ensuring quality—resulting in better-designed features that integrate seamlessly with your existing code.

This is the jj (Jujutsu) edition. The code-reviewer agent uses `jj diff` instead of `git diff` for identifying changes in the working copy.

## Command: `/feature-dev`

Launches a guided feature development workflow with 7 distinct phases.

**Usage:**
```bash
/feature-dev Add user authentication with OAuth
```

Or simply:
```bash
/feature-dev
```

## The 7-Phase Workflow

### Phase 1: Discovery
Understand what needs to be built.

### Phase 2: Codebase Exploration
Launch 2-3 code-explorer agents to understand relevant existing code and patterns.

### Phase 3: Clarifying Questions
Fill in gaps and resolve all ambiguities before designing.

### Phase 4: Architecture Design
Launch 2-3 code-architect agents to design multiple implementation approaches.

### Phase 5: Implementation
Build the feature (requires user approval).

### Phase 6: Quality Review
Launch 3 code-reviewer agents for quality checks.

### Phase 7: Summary
Document what was accomplished.

## Agents

### `code-explorer`
Deeply analyzes existing codebase features by tracing execution paths, mapping architecture, and documenting dependencies.

### `code-architect`
Designs feature architectures by analyzing existing codebase patterns and providing comprehensive implementation blueprints.

### `code-reviewer`
Reviews code for bugs, quality issues, and project conventions using confidence-based filtering (reports only issues with confidence >= 80).

## Installation

```bash
claude plugins add ./plugins/feature-dev-jj
```

## Requirements

- jj (Jujutsu) repository
- Project with existing codebase (workflow assumes existing code to learn from)

## Author

[muloka](https://github.com/muloka)

## Version

1.0.0
