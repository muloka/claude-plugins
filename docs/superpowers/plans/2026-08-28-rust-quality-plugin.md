# rust-quality Plugin (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `rust-quality` plugin whose generic Rust specialist is dispatchable through peer-review-jj's specialist discovery, plus the one-tier discovery-order extension that makes plugin-shipped specialists visible.

**Architecture:** A new prompt-only plugin (`plugins/rust-quality/`) ships `specialists/rust.md`; peer-review-jj's documented specialist walk gains an "installed plugins' `specialists/`" tier between user-global and its own built-ins (first-match-wins unchanged, so a project-local `rust.md` still shadows the plugin's). Marketplace metadata drops the jj-only framing.

**Tech Stack:** Markdown prompt files, JSON manifests, bash test suites (CI runs them on macOS **bash 3.2** — no globstar, no associative arrays, no `${var,,}`), `jq`.

**Spec:** `docs/superpowers/specs/2026-08-28-rust-quality-plugin-design.md`

## Global Constraints

- **jj, never git.** This repo bans raw git. Commit = `jj describe -m "<msg>"` on the current change, then `jj new` to open the next. Each task starts on a fresh empty `@` (the previous task's `jj new` provides it).
- **bash 3.2 compatibility** for anything under `tests/` (CI is macOS): `#!/usr/bin/env bash`, `set -euo pipefail`, PASS/FAIL counters, final `printf '%d passed, %d failed\n'` + `test "$FAIL" -eq 0`.
- **Version-bump invariant (CI-enforced):** any byte change under `plugins/<name>/` without a `plugin.json` version move fails the PR. Task 2 bumps peer-review-jj `0.6.3 → 0.7.0`. rust-quality starts at `0.1.0`.
- **READMEs never restate the plugin version** (heading-keyed lint `test-readme-no-version.sh`): no "Version" heading/section in the new README.
- Marketplace entries use `category: "productivity"` and the existing author block (`muloka` / `muloka@users.noreply.github.com`).
- CI test discovery is a glob over `plugins/*/tests/test-*.sh` — new suites are auto-found; nothing to register.
- `validate-frontmatter.yml` does **not** cover `specialists/*.md`; the plugin's own test suite carries that check instead.

---

### Task 1: rust-quality plugin scaffold + generic specialist

**Files:**
- Create: `plugins/rust-quality/.claude-plugin/plugin.json`
- Create: `plugins/rust-quality/specialists/rust.md`
- Create: `plugins/rust-quality/README.md`
- Test: `plugins/rust-quality/tests/test-rust-quality.sh`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: the concern-type contract — specialist file basename **is** the concern type, and frontmatter `name:` must equal it (`specialists/rust.md` → concern `rust`). Task 2's discovery docs and Task 3's marketplace entry rely on plugin name `rust-quality`, version `0.1.0`, path `plugins/rust-quality/`.

- [ ] **Step 1: Write the failing test**

Create `plugins/rust-quality/tests/test-rust-quality.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Structural contract for the rust-quality plugin: manifest is valid, the
# specialist file honors the basename-is-concern-type contract, and the
# frontmatter fields peer-review-jj's dispatch reads are present.
# (validate-frontmatter.yml does not cover specialists/*.md — this suite is
# the only check that frontmatter gets.)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$SCRIPT_DIR/.."

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

MANIFEST="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1; then
  ok "plugin.json exists and parses"
  jq -e '.name == "rust-quality"' "$MANIFEST" >/dev/null \
    && ok "manifest name is rust-quality" || bad "manifest/name" "$(jq -r .name "$MANIFEST")"
  jq -e '.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")' "$MANIFEST" >/dev/null \
    && ok "manifest version is semver" || bad "manifest/version" "$(jq -r .version "$MANIFEST")"
  jq -e 'has("hooks") | not' "$MANIFEST" >/dev/null \
    && ok "prompt-only plugin ships no hooks" || bad "manifest/hooks" "hooks present"
else
  bad "manifest" "missing or invalid JSON at $MANIFEST"
fi

SPECIALIST="$PLUGIN_ROOT/specialists/rust.md"
if [ -f "$SPECIALIST" ]; then
  ok "specialists/rust.md exists"
else
  bad "specialist" "missing $SPECIALIST"
fi

# Basename-is-concern-type: every specialist's frontmatter name equals its
# file basename. First-match-wins shadowing keys on this string.
for f in "$PLUGIN_ROOT"/specialists/*.md; do
  base="$(basename "$f" .md)"
  fmname="$(awk '/^---$/{n++; next} n==1 && $1=="name:"{print $2; exit}' "$f")"
  if [ "$fmname" = "$base" ]; then
    ok "specialist $base: frontmatter name matches basename"
  else
    bad "specialist $base" "frontmatter name is '$fmname'"
  fi
  grep -q '^model: ' "$f" \
    && ok "specialist $base: model pinned" || bad "specialist $base" "no model: line"
  grep -q '^description: ' "$f" \
    && ok "specialist $base: has description" || bad "specialist $base" "no description: line"
done

# Sections the receiving skill's template expects (refinement appends target
# '## Proposed Refinements' verbatim).
for sec in '## Role' '## Review Focus' '## Proposed Refinements'; do
  grep -qxF "$sec" "$SPECIALIST" \
    && ok "specialist has section: $sec" || bad "specialist/section" "missing $sec"
done

[ -f "$PLUGIN_ROOT/README.md" ] && ok "README exists" || bad "readme" "missing"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash plugins/rust-quality/tests/test-rust-quality.sh`
Expected: FAIL — "manifest missing or invalid JSON", and the `for f in specialists/*.md` loop errors or the specialist check reports missing (exit non-zero either way).

- [ ] **Step 3: Create the plugin manifest**

Create `plugins/rust-quality/.claude-plugin/plugin.json`:

```json
{
  "name": "rust-quality",
  "description": "Rust code-quality specialist for peer-review-jj — catches the recurring failure modes generic reviewers miss",
  "version": "0.1.0",
  "author": {
    "name": "muloka",
    "email": "muloka@users.noreply.github.com"
  }
}
```

- [ ] **Step 4: Create the generic Rust specialist**

Create `plugins/rust-quality/specialists/rust.md`:

```markdown
---
name: rust
description: Generic Rust specialist — recurring failure modes generic reviewers miss (clone, unwrap, collect, stringly-typed keys)
model: sonnet
---

## Role

You are a specialist reviewer for Rust code-quality issues. You review the
specific files and line ranges flagged by the generalist reviewer — do not
review beyond the flagged locations.

This is the *generic* Rust layer. Project-specific Rust rules live in the
project's own `.claude/peer-review/specialists/rust.md`, which — when present
— replaces this file entirely (first-match-wins, no merge). Never assume a
project convention that isn't visible in the code or its CLAUDE.md.

## Patterns

**Needless `.clone()`.** A clone where a borrow suffices: cloning to satisfy
a signature that could take `&str`/`&T`, cloning inside a loop when the value
is only read, `.to_owned()`/`.to_string()` feeding a function that borrows.
Suggest the borrow, `Cow`, or restructuring ownership. NOT a finding: clones
required to move across thread/task boundaries, clones of cheap `Copy`-like
handles (`Arc::clone` used deliberately), or clones the borrow checker
genuinely forces without a larger refactor.

**`unwrap()`/`expect()` in library code.** Library crates return `Result`;
panics belong at binary boundaries. Flag `unwrap()`, `expect()`, indexing
(`x[i]`, slicing) that can panic on untrusted input, and `unreachable!()`
guarding reachable states. NOT a finding: tests, benches, build scripts,
examples, `expect()` on invariants with a message proving why it holds, or
code that is clearly a binary's `main`/CLI layer.

**Premature `.collect()`.** `collect::<Vec<_>>()` immediately re-iterated
(`.iter()`, `.into_iter()`, a following `for`), or collected only to call
`.len()`/`.is_empty()`/`.contains()`. Suggest chaining the iterator or the
direct method (`count()`, `any()`). NOT a finding: collecting to break a
borrow, to dedupe via `HashSet`/`BTreeSet`, to reverse, or where the
collection is used more than once.

**Stringly-typed keys.** Raw `String`/`&str` crossing an API boundary where
the codebase already has a newtype for that value, or `as_str()` unwrapping a
newtype only for the raw value to travel onward and be compared or re-wrapped
later. Flag the boundary crossing, name the existing newtype. NOT a finding:
display/logging, serialization edges, or codebases with no newtype for the
value (suggesting a new newtype is a design proposal, not a review finding —
mention it at most once, as a note).

## Relevant Guidelines

The project's CLAUDE.md and visible architectural decisions override this
file. If a flagged pattern is explicitly permitted by the project (e.g. a
documented "unwrap is fine in this layer" rule), do not report it.

## Review Focus

Analyze the flagged locations for the patterns above. Verify before
flagging: read enough surrounding code to rule out the NOT-a-finding cases.
Return structured JSON findings using the same schema as the generalist,
with deeper analysis for your specialty and a concrete suggested fix per
finding.

## Proposed Refinements

(Generalist proposals appear here. Only humans promote them into the active prompt.)
```

- [ ] **Step 5: Create the plugin README**

Create `plugins/rust-quality/README.md` (no version heading — the
readme-no-version lint keys on headings):

```markdown
# rust-quality

Rust code-quality specialist for [peer-review-jj](../peer-review-jj/). Ships
a generic `rust` specialist that peer-review-jj's `/peer-review --deep rust`
dispatches to the files and line ranges the generalist flagged.

## What it catches

- Needless `.clone()` where a borrow, `Cow`, or restructured ownership suffices
- `unwrap()`/`expect()` and panicking indexing in library code
- Premature `.collect()` — collecting into a `Vec` only to iterate again
- Stringly-typed keys crossing boundaries where a newtype exists (including
  `as_str()` leaks past newtype barriers)

## Override model

Specialist discovery is first-match-wins: a project-local
`.claude/peer-review/specialists/rust.md` (or a user-global one under
`~/.claude/peer-review/specialists/`) **replaces** this plugin's specialist
entirely. Use that to encode project-specific rules (crate boundaries,
domain newtypes, dependency-specific traps) — start by copying this
plugin's `specialists/rust.md` and extending it.

## Requirements

- peer-review-jj ≥ 0.7.0 (the release whose specialist discovery includes
  installed plugins' `specialists/` directories)
```

- [ ] **Step 6: Run test to verify it passes**

Run: `/bin/bash plugins/rust-quality/tests/test-rust-quality.sh`
Expected: PASS — `N passed, 0 failed`, exit 0.

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat(rust-quality): new plugin — generic Rust specialist for peer-review dispatch"
jj new
```

---

### Task 2: peer-review-jj discovery-order extension

**Files:**
- Modify: `plugins/peer-review-jj/skills/receiving-change-review/SKILL.md:166` (step 9 discovery-order line)
- Modify: `plugins/peer-review-jj/commands/peer-review.md:136` (short-form discovery-order line)
- Modify: `plugins/peer-review-jj/.claude-plugin/plugin.json` (version `0.6.3` → `0.7.0`)
- Test: `plugins/peer-review-jj/tests/test-specialist-discovery.sh`

**Interfaces:**
- Consumes: Task 1's concern-type contract (basename = concern type; the glob below resolves `<concern>.md` by that name).
- Produces: the documented 4-tier discovery order that rust-quality's README (Task 1) and marketplace entry (Task 3) presuppose: project → user-global → installed plugins' `specialists/` → `peer-review-jj/agents/`.

- [ ] **Step 1: Write the failing test**

Create `plugins/peer-review-jj/tests/test-specialist-discovery.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Discovery-order contract: the specialist walk is documented in TWO places
# (receiving skill step 9, /peer-review command step 7). Both must name the
# installed-plugins tier, and the skill's line must order it between
# user-global and the peer-review-jj built-ins. Guards against the tiers
# drifting apart on a future edit.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$SCRIPT_DIR/.."
SKILL="$PLUGIN_ROOT/skills/receiving-change-review/SKILL.md"
CMD="$PLUGIN_ROOT/commands/peer-review.md"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

line="$(grep -F '**Discovery order**' "$SKILL" || true)"
if [ -n "$line" ]; then
  ok "SKILL.md has a discovery-order line"
  if printf '%s' "$line" | awk '{
      ug = index($0, "user-global");
      pl = index($0, "installed plugins");
      bi = index($0, "peer-review-jj/agents");
      exit !(ug && pl && bi && ug < pl && pl < bi);
    }'; then
    ok "tier order: user-global < installed plugins < built-in"
  else
    bad "skill/order" "$line"
  fi
else
  bad "skill/line" "no '**Discovery order**' line in $SKILL"
fi

grep -F 'plugins/cache' "$SKILL" >/dev/null \
  && ok "SKILL.md documents the cache glob for plugin specialists" \
  || bad "skill/glob" "no plugins/cache resolution documented"

grep -F "installed plugins" "$CMD" >/dev/null \
  && ok "command doc names the installed-plugins tier" \
  || bad "cmd/tier" "peer-review.md discovery line not updated"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `/bin/bash plugins/peer-review-jj/tests/test-specialist-discovery.sh`
Expected: FAIL — "tier order" (no `installed plugins` on the line), "cache glob", and "command doc" all red; exit 1.

- [ ] **Step 3: Update the receiving skill's discovery order**

In `plugins/peer-review-jj/skills/receiving-change-review/SKILL.md`, replace this exact line (currently line 166):

```markdown
1. **Discovery order**: project (`.claude/peer-review/specialists/`) → user-global (`~/.claude/peer-review/specialists/`) → plugin built-in (`peer-review-jj/agents/`)
```

with:

```markdown
1. **Discovery order**: project (`.claude/peer-review/specialists/`) → user-global (`~/.claude/peer-review/specialists/`) → installed plugins' `specialists/` directories → plugin built-in (`peer-review-jj/agents/`). Resolve the installed-plugins tier for a concern with the version-sorted cache glob `ls ~/.claude/plugins/cache/*/*/*/specialists/<concern>.md 2>/dev/null | sort -V | tail -1` (a local checkout of the plugins repo has them at `plugins/<plugin>/specialists/<concern>.md` instead); if the glob matches nothing, the tier is empty and the walk continues.
```

- [ ] **Step 4: Update the command's short-form discovery line**

In `plugins/peer-review-jj/commands/peer-review.md`, replace this exact line (currently line 136):

```markdown
- Discovery order: project → user-global → plugin built-in
```

with:

```markdown
- Discovery order: project → user-global → installed plugins' `specialists/` → plugin built-in
```

- [ ] **Step 5: Bump peer-review-jj version**

In `plugins/peer-review-jj/.claude-plugin/plugin.json`, change:

```json
  "version": "0.6.3",
```

to:

```json
  "version": "0.7.0",
```

(Contract change → minor bump; the require-version-bump CI job fails the PR without it, and the plugin cache is keyed by version — no bump, no ship.)

- [ ] **Step 6: Run test to verify it passes**

Run: `/bin/bash plugins/peer-review-jj/tests/test-specialist-discovery.sh`
Expected: PASS — `4 passed, 0 failed`, exit 0.

- [ ] **Step 7: Run the plugin's existing suite (regression)**

Run: `/bin/bash plugins/peer-review-jj/tests/test-review-history.sh`
Expected: PASS — the discovery edit must not disturb history/emergence behavior.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat(peer-review-jj): specialist discovery gains installed-plugins tier (0.7.0)"
jj new
```

---

### Task 3: marketplace entry + de-jj the storefront

**Files:**
- Modify: `.claude-plugin/marketplace.json` (top-level `description`; append `rust-quality` to `plugins[]`)
- Modify: `README.md` (repo README title + intro sentence)
- Test: `plugins/rust-quality/tests/test-rust-quality.sh` (append marketplace assertions)

**Interfaces:**
- Consumes: plugin name `rust-quality`, source path `./plugins/rust-quality` (Task 1).
- Produces: nothing downstream — terminal task.

- [ ] **Step 1: Extend the test with marketplace assertions**

In `plugins/rust-quality/tests/test-rust-quality.sh`, insert before the final `printf '%d passed, %d failed\n' "$PASS" "$FAIL"` line:

```bash
# Marketplace registration: the entry exists, points at the right source,
# and the storefront description is no longer jj-only.
REPO_ROOT="$SCRIPT_DIR/../../.."
MARKET="$REPO_ROOT/.claude-plugin/marketplace.json"
jq -e '.plugins[] | select(.name == "rust-quality")' "$MARKET" >/dev/null \
  && ok "marketplace lists rust-quality" || bad "marketplace/entry" "no rust-quality entry"
jq -e '.plugins[] | select(.name == "rust-quality") | .source == "./plugins/rust-quality"' "$MARKET" >/dev/null \
  && ok "marketplace source path correct" || bad "marketplace/source" "$(jq -r '.plugins[] | select(.name == "rust-quality") | .source' "$MARKET")"
jq -e '.description | contains("Rust")' "$MARKET" >/dev/null \
  && ok "marketplace description mentions Rust" || bad "marketplace/description" "$(jq -r .description "$MARKET")"
```

- [ ] **Step 2: Run test to verify the new assertions fail**

Run: `/bin/bash plugins/rust-quality/tests/test-rust-quality.sh`
Expected: FAIL — the three marketplace assertions red (entry absent, description unchanged); earlier assertions still green; exit 1.

- [ ] **Step 3: Update marketplace.json**

In `.claude-plugin/marketplace.json`:

1. Change the top-level description from:

```json
  "description": "jj (Jujutsu) plugins for Claude Code — project setup, commit workflows, peer review, and workspace isolation",
```

to:

```json
  "description": "muloka's Claude Code plugins — jj (Jujutsu) workflows, code review, and Rust code quality",
```

2. Append to the `plugins` array (after the `agent-helpers-jj` entry, before the closing `]`):

```json
    {
      "name": "rust-quality",
      "description": "Rust code-quality specialist for peer-review-jj — catches the recurring failure modes generic reviewers miss",
      "author": {
        "name": "muloka",
        "email": "muloka@users.noreply.github.com"
      },
      "source": "./plugins/rust-quality",
      "category": "productivity",
      "homepage": "https://github.com/muloka/claude-plugins/tree/main/plugins/rust-quality"
    }
```

- [ ] **Step 4: Reword the repo README intro**

In `README.md`, replace:

```markdown
# Claude Code Plugins for jj (Jujutsu)

Claude Code plugins for **jj (Jujutsu)** workflows — project setup, workspace isolation, commit management, peer review, and a hard wall against raw `git`.
```

with:

```markdown
# muloka's Claude Code Plugins

Claude Code plugins — **jj (Jujutsu)** workflows (project setup, workspace isolation, commit management, peer review, and a hard wall against raw `git`) and **Rust** code quality.
```

Leave the rest of the README untouched.

- [ ] **Step 5: Run test to verify it passes**

Run: `/bin/bash plugins/rust-quality/tests/test-rust-quality.sh`
Expected: PASS — `N passed, 0 failed`, exit 0.

- [ ] **Step 6: Run every plugin suite (full local regression)**

```bash
for t in plugins/*/tests/test-*.sh; do
  echo "== $t"
  /bin/bash "$t" || { echo "SUITE FAILED: $t"; exit 1; }
done
```

Expected: all suites pass. (Repo-level `.github/tests/` and the version-bump workflow run in CI on the PR.)

- [ ] **Step 7: Commit**

```bash
jj describe -m "feat: register rust-quality in marketplace; storefront is muloka's plugins, not jj-only"
jj new
```

---

## Out of scope (from the spec)

- tokotoko's project-local `.claude/peer-review/specialists/rust.md` — lives in the tokotoko repo (follow-up there, seeded by copying this plugin's specialist and adding petgraph/`TokenPath`/toko-core rules).
- Generalist reviewer and findings schema — untouched.
- Phases 2 (writing-time skills) and 3 (debt inventory) — roadmap only.
