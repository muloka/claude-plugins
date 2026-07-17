# Require Plugin Version Bump in CI (#84) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fail CI red when a PR changes any file under `plugins/<name>/` without bumping that plugin's `version`, so version-keyed-cache staleness can never ship silently.

**Architecture:** A dependency-free bash script (`require-version-bump.sh`) holds the decision logic with its inputs injected (the PR's changed-file list and a base git ref), making it unit-testable in a throwaway git repo. A thin `pull_request` workflow feeds it real inputs on ubuntu-latest. A local suite proves fail-first. The existing `#82` workflow-glob lint is generalized so this PR's new `paths:`-gated workflow doesn't ship an unguarded glob.

**Tech Stack:** GitHub Actions, POSIX shell / bash (3.2-safe), `gh` CLI, git, jj (VCS).

## Global Constraints

- **bash 3.2 safe** — the script and both suites run on macOS bash 3.2.57 in CI (`test.yml` runner) as well as ubuntu bash 5. No associative arrays, no `mapfile`/`readarray`, no globstar, no `${var,,}`.
- **No `jq`** — the local Mac may lack it; parse JSON `version` with `sed`.
- **Run suites with `/bin/bash`, never interactive zsh** — a green zsh run went red on CI's bash in #90.
- **Workflow runs on `ubuntu-latest`** — matches `validate-frontmatter.yml`; `gh` + bash 5 present.
- **VCS is jj** — never raw git for repo operations; commit via `jj commit -m`. The script, the suite, and the local proof use **no VCS at all** (the base tree is obtained by the CI workflow's second checkout, and the suite fakes it with plain dirs) — this is required, because this session's jj rail blocks raw `git` even inside scripts.
- **Conventional commits, `ci:` scope** — matches recent history (`ci: invariant lints…`).
- **Self-application:** this PR touches only `.github/` and `docs/` — no `plugins/<name>/` — so it correctly does not require a plugin version bump of itself. Do **not** add fixtures under real plugin dirs (the test builds its own throwaway repos).

**Spec:** `docs/superpowers/specs/2026-07-16-require-version-bump-design.md`

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `.github/scripts/require-version-bump.sh` | decision logic (pure; env-injected inputs) | 1 (create) |
| `.github/tests/test-require-version-bump.sh` | fail-first proof over a throwaway git repo | 1 (create) |
| `.github/workflows/require-version-bump.yml` | CI wrapper: feeds real inputs on plugin PRs | 2 (create) |
| `.github/tests/test-workflow-globs.sh` | #82 glob lint, generalized to all workflows | 3 (modify) |

---

## Task 1: Decision script + fail-first suite

**Files:**
- Create: `.github/scripts/require-version-bump.sh`
- Create (test): `.github/tests/test-require-version-bump.sh`

**Interfaces:**
- Produces: an executable script read by Task 2's workflow. Contract: reads env `CHANGED_FILES` (newline-separated repo-relative paths) and `BASE_DIR` (a directory holding a checkout of the PR's base ref), reads head versions from the working tree (cwd = repo root) and base versions from `"$BASE_DIR/<manifest>"`, exits `1` if any changed plugin's version equals its base version, else `0`, emitting one `::error::` line per offender. **No git/jj** — plain file reads only.

- [ ] **Step 1: Write the failing test suite**

Create `.github/tests/test-require-version-bump.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Proves require-version-bump.sh: RED when a plugin's files change without a
# version bump, GREEN otherwise. No VCS — each case builds a head/ tree and a
# base/ tree as plain directories (BASE_DIR), exactly what the workflow's second
# checkout provides. This runs even under the jj rail (no `git` anywhere).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/require-version-bump.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# new_case -> prints a fresh dir holding empty head/ and base/ subtrees
new_case() {
  local d; d="$(mktemp -d "$TMPROOT/c.XXXXXX")"
  mkdir -p "$d/head" "$d/base"
  printf '%s' "$d"
}

# manifest <tree> <plugin> <version>
manifest() {
  mkdir -p "$1/plugins/$2/.claude-plugin"
  printf '{\n  "name": "%s",\n  "version": "%s"\n}\n' "$2" "$3" \
    > "$1/plugins/$2/.claude-plugin/plugin.json"
}

# file <path> <contents>
file() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

# run <case_dir> <changed_files> -> echoes the script's exit code
run() {
  local rc=0
  ( cd "$1/head" && CHANGED_FILES="$2" BASE_DIR="$1/base" bash "$SCRIPT" ) >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

# --- case 1: plugin file changed, version NOT bumped -> RED (the core proof) ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0; file "$C/base/plugins/foo/skills/x/SKILL.md" v1
manifest "$C/head" foo 0.1.0; file "$C/head/plugins/foo/skills/x/SKILL.md" v2
rc="$(run "$C" 'plugins/foo/skills/x/SKILL.md')"
[ "$rc" = 1 ] && ok "case1: changed without bump -> red" || bad "case1" "rc=$rc want 1"

# --- case 2: plugin file changed AND version bumped -> GREEN ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0; file "$C/base/plugins/foo/skills/x/SKILL.md" v1
manifest "$C/head" foo 0.1.1; file "$C/head/plugins/foo/skills/x/SKILL.md" v2
rc="$(run "$C" "$(printf 'plugins/foo/skills/x/SKILL.md\nplugins/foo/.claude-plugin/plugin.json')")"
[ "$rc" = 0 ] && ok "case2: changed with bump -> green" || bad "case2" "rc=$rc want 0"

# --- case 3: no plugin files changed -> GREEN (script no-ops) ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0
manifest "$C/head" foo 0.1.0
rc="$(run "$C" '.github/workflows/foo.yml')"
[ "$rc" = 0 ] && ok "case3: no plugin change -> green" || bad "case3" "rc=$rc want 0"

# --- case 4: brand-new plugin (absent in base) -> GREEN ---
C="$(new_case)"
manifest "$C/head" newp 0.1.0; file "$C/head/plugins/newp/skills/x/SKILL.md" v1
rc="$(run "$C" "$(printf 'plugins/newp/.claude-plugin/plugin.json\nplugins/newp/skills/x/SKILL.md')")"
[ "$rc" = 0 ] && ok "case4: new plugin -> green" || bad "case4" "rc=$rc want 0"

# --- case 5: full plugin deletion (absent in head) -> GREEN ---
C="$(new_case)"
manifest "$C/base" gone 0.1.0; file "$C/base/plugins/gone/skills/x/SKILL.md" v1
rc="$(run "$C" "$(printf 'plugins/gone/.claude-plugin/plugin.json\nplugins/gone/skills/x/SKILL.md')")"
[ "$rc" = 0 ] && ok "case5: full deletion -> green" || bad "case5" "rc=$rc want 0"

# --- case 6: two plugins, one bumped one not -> RED, names only the unbumped ---
C="$(new_case)"
manifest "$C/base" foo 0.1.0; file "$C/base/plugins/foo/skills/x/SKILL.md" v1
manifest "$C/base" bar 0.1.0; file "$C/base/plugins/bar/skills/y/SKILL.md" v1
manifest "$C/head" foo 0.1.1; file "$C/head/plugins/foo/skills/x/SKILL.md" v2
manifest "$C/head" bar 0.1.0; file "$C/head/plugins/bar/skills/y/SKILL.md" v2
CF="$(printf 'plugins/foo/skills/x/SKILL.md\nplugins/foo/.claude-plugin/plugin.json\nplugins/bar/skills/y/SKILL.md')"
out="$( cd "$C/head" && CHANGED_FILES="$CF" BASE_DIR="$C/base" bash "$SCRIPT" 2>&1 )" && rc=0 || rc=$?
[ "$rc" = 1 ] && ok "case6: mixed -> red" || bad "case6" "rc=$rc want 1"
printf '%s' "$out" | grep -q "bar" && ok "case6: names unbumped 'bar'" || bad "case6-name" "no bar in: $out"
printf '%s' "$out" | grep -q "'foo'" && bad "case6-name" "bumped foo wrongly flagged" || ok "case6: bumped 'foo' not flagged"

echo ""
echo "$pass passed, $fail failed"
test "$fail" -eq 0
```

- [ ] **Step 2: Run the suite to verify it fails (script does not exist yet)**

Run: `/bin/bash .github/tests/test-require-version-bump.sh`
Expected: FAIL — every case reports a nonzero/blank rc because `bash "$SCRIPT"` cannot find `require-version-bump.sh`; the suite ends `X passed, Y failed` with `Y > 0` and exits nonzero. (This confirms the test actually exercises the script rather than passing vacuously.)

- [ ] **Step 3: Write the decision script**

Create `.github/scripts/require-version-bump.sh`:

```bash
#!/usr/bin/env bash
# Fail if a PR changes files under plugins/<name>/ without bumping that
# plugin's version in plugins/<name>/.claude-plugin/plugin.json.
#
# Why (#84): the Claude plugin cache is keyed by version STRING. If content
# changes but the version does not, `claude plugin update` sees equal versions,
# prints "already at the latest version", and never re-fetches — the change
# ships to nobody. A green checkmark over stale content.
#
# Inputs (env), injected so this is testable with no VCS at all:
#   CHANGED_FILES  newline-separated repo-relative paths the PR touched
#   BASE_DIR       path to a checkout of the PR's base ref; base versions are
#                  read from "$BASE_DIR/<manifest>". A manifest absent there
#                  means the plugin is new in this PR.
# Head versions are read from the working tree (cwd = repo root).
#
# Runs on ubuntu bash 5 in CI and macOS bash 3.2 in the suite — keep it
# 3.2-safe: no associative arrays, no mapfile, no globstar, no jq. No git/jj:
# obtaining the base tree is the workflow's job (a second checkout).
set -euo pipefail

CHANGED_FILES="${CHANGED_FILES:-}"
BASE_DIR="${BASE_DIR:-}"

# Extract the top-level "version" string from a plugin.json on stdin. Our own
# controlled manifests carry exactly one "version" key, so this is safe.
version_of() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Unique plugin names with any changed file under plugins/<name>/.
# Paths directly under plugins/ (e.g. plugins/.DS_Store) have no <name>/ and
# are correctly ignored.
plugins=$(printf '%s\n' "$CHANGED_FILES" \
  | sed -n 's#^plugins/\([^/]*\)/.*#\1#p' \
  | sort -u)

failed=0
# Here-string, NOT a pipe: `... | while` runs the loop in a subshell, losing
# `failed`, so the script would exit 0 over an unbumped change — #84 inside its
# own fix.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  manifest="plugins/$name/.claude-plugin/plugin.json"

  # Full plugin deletion (manifest gone at head): nothing to bump — skip.
  [ -f "$manifest" ] || continue

  head_ver=$(version_of < "$manifest")

  # Base manifest absent => plugin is new in this PR => nothing to bump.
  base_manifest="$BASE_DIR/$manifest"
  if [ -f "$base_manifest" ]; then
    base_ver=$(version_of < "$base_manifest")
  else
    base_ver=""
  fi

  if [ -n "$base_ver" ] && [ "$base_ver" = "$head_ver" ]; then
    echo "::error::plugin '$name' changed but its version is still $head_ver — bump $manifest (the cache is keyed by version; an unbumped change never re-fetches, see #84)"
    failed=1
  fi
done <<< "$plugins"

exit "$failed"
```

Then make it executable:

```bash
chmod +x .github/scripts/require-version-bump.sh
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `/bin/bash .github/tests/test-require-version-bump.sh`
Expected: PASS — every case's `ok`, final line `8 passed, 0 failed` (6 exit-code checks + 2 name checks in case 6), exit 0.

- [ ] **Step 5: Commit**

```bash
jj commit -m "ci: add require-version-bump check and suite for #84"
```

---

## Task 2: CI workflow wrapper

**Files:**
- Create: `.github/workflows/require-version-bump.yml`

**Interfaces:**
- Consumes: `.github/scripts/require-version-bump.sh` from Task 1 (env contract: `CHANGED_FILES`, `BASE_DIR`).
- Produces: a `paths: ['plugins/**']`-gated workflow — Task 3's generalized lint will assert this glob is live.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/require-version-bump.yml`:

```yaml
name: Require Version Bump

on:
  pull_request:
    paths:
      - 'plugins/**'

jobs:
  require-version-bump:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4          # PR head into the workspace root

      - uses: actions/checkout@v4          # PR base into ./_base for comparison
        with:
          ref: ${{ github.event.pull_request.base.sha }}
          path: _base

      - name: Require a version bump for any changed plugin
        env:
          GH_TOKEN: ${{ github.token }}
          BASE_DIR: _base
        run: |
          CHANGED_FILES="$(gh pr diff ${{ github.event.pull_request.number }} --name-only)"
          export CHANGED_FILES
          bash .github/scripts/require-version-bump.sh
```

Note: head is checked out first (into the root), then base into the `_base` subdir — the
second checkout cleans only `_base` and leaves head intact. No `fetch-depth` is needed:
the base checkout fetches exactly its `ref`. The script reads plain files from both trees.

- [ ] **Step 2: Sanity-check the YAML parses**

Run: `python3 -c 'import yaml,sys; yaml.safe_load(open(".github/workflows/require-version-bump.yml")); print("ok")'`
Expected: `ok` (no parse error). If `python3`/`yaml` is unavailable, instead run `ruby -ryaml -e 'YAML.load_file(".github/workflows/require-version-bump.yml"); puts "ok"'`.

- [ ] **Step 3: Verify the wrapper feeds the script correctly (offline dry-run)**

Confirm the wiring: two `actions/checkout` steps (head, then base into `_base`), `BASE_DIR: _base`, `CHANGED_FILES` from `gh pr diff --name-only`, and the correct script path.

Run: `grep -nE 'checkout|BASE_DIR|CHANGED_FILES|require-version-bump.sh|_base' .github/workflows/require-version-bump.yml`
Expected: two `actions/checkout@v4` lines, `path: _base`, `ref: ${{ github.event.pull_request.base.sha }}`, `BASE_DIR: _base`, the `CHANGED_FILES="$(gh pr diff …)"` line, and `bash .github/scripts/require-version-bump.sh`.

(True end-to-end proof happens live in the Finalization section — a workflow cannot be run offline.)

- [ ] **Step 4: Commit**

```bash
jj commit -m "ci: gate plugin PRs on require-version-bump (#84)"
```

---

## Task 3: Generalize the workflow-glob lint to all workflows

**Files:**
- Modify: `.github/tests/test-workflow-globs.sh` (currently hardcodes `WF=validate-frontmatter.yml` at line 21)

**Interfaces:**
- Consumes: `.github/workflows/require-version-bump.yml` from Task 2 (the second `paths:`-gated workflow this now covers).
- Produces: nothing downstream — this is test infrastructure.

**Why:** the lint asserts every `paths:` glob a workflow gates on matches ≥1 file (a dead glob = silent no-trigger = false green, #77). It currently checks only `validate-frontmatter.yml`. Task 2 adds a second `paths:`-gated workflow; leaving the lint single-file ships an unguarded glob inside the family's capstone. Generalize it to iterate all workflows.

- [ ] **Step 1: Replace the single-file body with an all-workflows loop**

In `.github/tests/test-workflow-globs.sh`, replace everything from the `WF=` line (21) through the end of the extract-and-check block (the `fi` around line 73) with the following. Keep the header comment (lines 1–18), `set -euo pipefail`, `ROOT=`, `ok`/`bad`, and the `_glob_to_findpath` / `_glob_match_count` helpers unchanged.

Replace this current block:

```bash
WF="$ROOT/.github/workflows/validate-frontmatter.yml"
PASS=0
FAIL=0
```

with:

```bash
PASS=0
FAIL=0
```

Replace the current extraction + check block (the `globs=$(awk … "$WF")` assignment, the `n=$(…)` count, and the `if [ "$n" -eq 0 ] … fi` block, lines ~44–73) with:

```bash
# Extract the quoted entries under `paths:` in a workflow file.
extract_globs() {
  awk '
    /^[[:space:]]*paths:/ {inpaths=1; next}
    inpaths && /^[[:space:]]*-[[:space:]]/ {
      line=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      gsub(/^['\''"]|['\''"]$/, "", line)
      print line
      next
    }
    inpaths && /^[[:space:]]*[^[:space:]-]/ {inpaths=0}
  ' "$1"
}

# Check EVERY workflow, not one hardcoded file: any paths:-gated workflow can
# rot a glob (#77). A hardcoded single file is #82 inside the fix for #82.
total_globs=0
for wf in "$ROOT"/.github/workflows/*.yml; do
  name="$(basename "$wf")"
  globs="$(extract_globs "$wf")"
  # `|| true`: grep -c exits 1 on zero matches, which set -e would treat as fatal.
  n=$(printf '%s\n' "$globs" | grep -c . || true)
  # A workflow with no paths: filter is legitimate (test.yml, close-external-prs.yml).
  [ "$n" -eq 0 ] && continue
  ok "extracted $n glob(s) from $name"
  total_globs=$((total_globs + n))
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    c=$(_glob_match_count "$g")
    if [ "$c" -gt 0 ]; then
      ok "$name: $g matches $c file(s)"
    else
      bad "$name: $g matches ZERO files — the workflow gates on it but it is dead (see #77)"
    fi
  done <<< "$globs"
done

# Backstop (#82 applied to itself): we KNOW at least validate-frontmatter.yml and
# require-version-bump.yml gate on paths. Zero globs across ALL workflows means
# the parser broke or every filter vanished — fail loud, never pass by doing nothing.
if [ "$total_globs" -eq 0 ]; then
  bad "no paths: globs found in ANY workflow — the parser or the workflows changed"
fi
```

Leave the final `echo` / `test "$FAIL" -eq 0` tail unchanged.

- [ ] **Step 2: Run the generalized lint — it now covers both workflows and passes**

Run: `/bin/bash .github/tests/test-workflow-globs.sh`
Expected: PASS. Output includes `extracted N glob(s) from validate-frontmatter.yml` **and** `extracted 1 glob(s) from require-version-bump.yml`, plus `require-version-bump.yml: plugins/** matches C file(s)` with `C > 0`. Final line `X passed, 0 failed`, exit 0.

- [ ] **Step 3: Verify the lint would actually catch a dead glob (temporary mutation, reverted)**

This proves the generalization has teeth, not just that it passes today.

```bash
# Point the new workflow's glob at a path that matches nothing, run, expect FAIL:
cp .github/workflows/require-version-bump.yml /tmp/rvb.bak
sed -i.bak "s#- 'plugins/\*\*'#- 'nonexistent-dir/**'#" .github/workflows/require-version-bump.yml
/bin/bash .github/tests/test-workflow-globs.sh; echo "exit=$?"
# restore:
cp /tmp/rvb.bak .github/workflows/require-version-bump.yml
rm -f .github/workflows/require-version-bump.yml.bak /tmp/rvb.bak
```

Expected: the run reports `nonexistent-dir/** matches ZERO files …` and `exit=1`. After restore, `git diff`/`jj diff` shows the workflow unchanged.

- [ ] **Step 4: Commit**

```bash
jj commit -m "ci: generalize workflow-glob lint to all workflows (#84)"
```

---

## Finalization (live end-to-end proof + PR)

A workflow can only be proven by running on GitHub. Do this after Tasks 1–3 are committed.

- [ ] **Step 1: Push the branch and open the PR**

```bash
jj bookmark create require-version-bump-84 -r @-
jj git push --bookmark require-version-bump-84 --allow-new
gh pr create --fill --title "ci: require plugin version bump (#84)"
```

- [ ] **Step 2: Confirm CI is green on this PR**

This PR touches only `.github/` and `docs/` — no `plugins/<name>/` — so `require-version-bump` should not even trigger (paths filter), and `Tests` (which runs both new suites via its glob) should pass.

Run: `gh pr checks --watch`
Expected: `Tests` passes (both new suites green); `Require Version Bump` is absent or skipped (no plugin changed).

- [ ] **Step 3: Prove the gate RED, then GREEN, with a throwaway commit on the PR branch**

```bash
# Touch a real plugin WITHOUT bumping — expect the gate to fail red:
echo "" >> plugins/workspace-jj/README.md
jj commit -m "test: trip require-version-bump (temporary)"
jj git push --bookmark require-version-bump-84
gh pr checks --watch    # expect: Require Version Bump == fail
```

Expected: `Require Version Bump` reports failure, annotation names `workspace-jj`.

```bash
# Now bump the version — expect green:
# edit plugins/workspace-jj/.claude-plugin/plugin.json version 0.1.2 -> 0.1.3
jj commit -m "test: bump workspace-jj to satisfy the gate (temporary)"
jj git push --bookmark require-version-bump-84
gh pr checks --watch    # expect: Require Version Bump == pass
```

Expected: `Require Version Bump` passes.

- [ ] **Step 4: Revert the throwaway proof commits**

The two `test:` commits were proof-of-behavior only and must not merge. Abandon them so the PR contains only the four intended files.

```bash
# abandon the two temporary changes, keeping Tasks 1–3:
jj abandon -r 'description(glob:"test: *temporary*")'
jj git push --bookmark require-version-bump-84
```

Expected: `jj log` / `gh pr diff` shows only the Task 1–3 files (script, two suites, workflow) plus the spec and plan docs — no plugin edits, no version bumps.

- [ ] **Step 5: Final green + merge readiness**

Run: `gh pr checks`
Expected: all checks green, PR contains exactly the intended change set. Ready for review/merge.

---

## Self-Review

**Spec coverage** (each spec section → task):
- Decision logic / `version_of` / here-string / base-dir read → Task 1, Step 3 (verbatim).
- 6 test cases (table) → Task 1, Step 1 (all six, +2 name checks in case 6).
- Workflow (ubuntu, two checkouts head+`_base`, `BASE_DIR`, `gh pr diff`, `paths: plugins/**`) → Task 2.
- Generalized glob lint (iterate all workflows, skip no-paths, aggregate-zero backstop, per-file messaging) → Task 3.
- Edge decisions (partial vs full deletion, new plugin, self-application) → covered by cases 4/5, and the self-application constraint + Finalization Step 4.
- Proof plan (local fail-first, glob-lint regression, live end-to-end) → Task 1 Step 4, Task 3 Step 2, Finalization.
- Known out-of-scope risk (branch-protection `paths` footgun) → intentionally not implemented; documented in spec only. No task, by design.

**Placeholder scan:** every code step contains complete, runnable content; no TBD/TODO/"similar to". ✔

**Type/name consistency:** `CHANGED_FILES`, `BASE_DIR`, `version_of`, `plugins`, `failed`, `manifest`, `head_ver`, `base_ver`, `base_manifest` are used identically across the script (Task 1) and the suite's `run`/env wiring (Task 1) and workflow (Task 2). No `git`/`jj`/`BASE_REF`/`fetch-depth` remain anywhere. Lint helpers `_glob_to_findpath`/`_glob_match_count` referenced in Task 3 already exist in the file and are left unchanged. ✔
