#!/usr/bin/env bash
# Verifies that every relative script reference in a skill body resolves.
#
# Why this exists: PR #81 moved skills from skills/<name>.md to
# skills/<name>/SKILL.md — one directory deeper. Every `../scripts/...`
# reference in the body silently became wrong, and six of them shipped in
# 0.1.1. Nothing caught it: the script tests exercise the scripts directly,
# not the skill's references to them; CI validates frontmatter, not paths; and
# the skill was unreachable anyway (a command of the same name shadowed it), so
# the paths were never executed. Prose is not run, so it is not checked.
#
# The skill's convention is "script paths are relative to this skill file's
# directory". That is sound — the Skill tool announces the base directory on
# load — but nothing verified the paths were true.
#
# Design note: this extracts the WHOLE reference (all leading ../ included) and
# resolves it. It does not try to pattern-match the *wrong* form. That matters:
# `../../scripts/` CONTAINS the substring `../scripts/`, so a detector for the
# bad form reports the correct form as a bug unless carefully anchored.
# Resolution sidesteps the trap entirely and also catches renamed or deleted
# scripts for free.
#
# Usage: test-skill-paths.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLUGINS="$ROOT/plugins"
PASS=0
FAIL=0
REFS=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# --- Rule 1: every relative script reference resolves ---
while IFS= read -r skill; do
  dir=$(dirname "$skill")
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    REFS=$((REFS+1))
    if [ -e "$dir/$ref" ]; then
      ok "$(basename "$dir")/$(basename "$skill"): $ref"
    else
      bad "$(basename "$dir")/$(basename "$skill"): $ref does not resolve (tried $dir/$ref)"
    fi
  done < <(grep -oE '(\.\./)+scripts/[A-Za-z0-9_.-]+' "$skill" | sort -u)
done < <(find "$PLUGINS" -path '*/skills/*/SKILL.md' | sort)

# --- Rule 2: finding zero references means the extractor is broken ---
#
# A lint that checks nothing passes silently, which is the failure this repo
# has hit repeatedly (#82: a glob matching zero files; #84: an unchanged
# version). At least one skill here references scripts. Zero matches means the
# regex rotted, not that the repo is clean.
if [ "$REFS" -eq 0 ]; then
  bad "no script references found in any skill — the extractor is broken, not the repo clean"
else
  ok "extractor found $REFS script reference(s)"
fi

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
