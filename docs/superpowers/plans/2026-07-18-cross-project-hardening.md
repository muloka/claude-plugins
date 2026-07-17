# Cross-Project Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gate the raw-git block on jj-repo presence so the plugins are usable at user (global) scope (#45), and make the primary permission gate fail closed on unparseable input (#70).

**Architecture:** Two independent changes to shell PreToolUse hooks. #45 adds a `.jj`-directory walk-up at the top of `block-raw-git.sh` and unifies its three drifted copies into one byte-identical superset, guarded by a new drift-detecting test. #70 mirrors the `ERR`-trap fail-closed construct from the sibling `gate-config-writes.sh` into `permission-gate.sh` and proves via test that it never fires a wrong-direction decision.

**Tech Stack:** POSIX-ish bash, `jq`, `shasum`. Tests are plain bash suites run by `.github/workflows/test.yml`.

**Spec:** `docs/superpowers/specs/2026-07-17-cross-project-hardening-design.md`

## Global Constraints

- **VCS is jj (Jujutsu), not git.** The working copy IS a commit. "Commit" steps below use `jj describe` to set the message and `jj new` to start the next task's change. Never run raw `git` — a PreToolUse hook blocks it. Use `gh` for GitHub.
- **bash 3.2 compatibility (hard requirement).** Suites run on macOS `/bin/bash` (3.2.57) and ubuntu bash 5. No globstar (`**`), no associative arrays, no `mapfile`. Detection loops use `while [ "$dir" != "/" ]` + `dirname`.
- **CI fails red on an unbumped plugin (#84).** Any changed byte under `plugins/<name>/` — including test files — requires bumping that plugin's `version` in `plugins/<name>/.claude-plugin/plugin.json`. Required bumps: `commit-commands-jj` 0.1.0→0.1.1, `peer-review-jj` 0.1.1→0.1.2, `project-setup-jj` 0.1.1→0.1.2, `permission-gateway` 0.1.0→0.1.1.
- **Test discovery glob:** `find plugins .github -path '*/tests/test-*.sh'`. New suites must live at `plugins/<name>/tests/test-*.sh` to be found.
- **The three `block-raw-git.sh` copies must end byte-identical** (same sha256), taking `project-setup-jj`'s superset as canonical. Enforced by a drift-guard test.

---

## Task 1: #45 — gate `block-raw-git.sh` on jj-repo presence + unify copies

**Files:**
- Create: `plugins/project-setup-jj/tests/test-block-raw-git.sh`
- Modify: `plugins/project-setup-jj/scripts/block-raw-git.sh` (add gate after `input=$(cat)`)
- Modify: `plugins/commit-commands-jj/scripts/block-raw-git.sh` (replace with canonical copy)
- Modify: `plugins/peer-review-jj/scripts/block-raw-git.sh` (replace with canonical copy)
- Modify: `plugins/commit-commands-jj/.claude-plugin/plugin.json` (0.1.0→0.1.1)
- Modify: `plugins/peer-review-jj/.claude-plugin/plugin.json` (0.1.1→0.1.2)
- Modify: `plugins/project-setup-jj/.claude-plugin/plugin.json` (0.1.1→0.1.2)

**Interfaces:**
- Consumes: the PreToolUse hook payload on stdin — a JSON object with `.tool_input.command` (string) and `.cwd` (absolute path string, may be absent).
- Produces: nothing consumed by later tasks (Task 2 is independent). Behavioral contract: inside a jj repo (a `.jj` directory at `.cwd` or any ancestor) the hook emits a `deny` JSON for raw `git`/git-internals and `exit 0`; outside a jj repo it emits nothing and `exit 0` (pass-through).

- [ ] **Step 1: Write the failing test suite**

Create `plugins/project-setup-jj/tests/test-block-raw-git.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# project-setup-jj is the canonical superset copy; behaviour is tested against
# it, and the drift-guard proves the other two are byte-identical.
HOOK="$REPO_ROOT/plugins/project-setup-jj/scripts/block-raw-git.sh"

COPIES="plugins/commit-commands-jj/scripts/block-raw-git.sh
plugins/peer-review-jj/scripts/block-raw-git.sh
plugins/project-setup-jj/scripts/block-raw-git.sh"

pass=0
fail=0

# Run the hook with a command + cwd; capture stdout (hook never uses stderr).
run_hook() {
  local cmd="$1"
  local cwd="$2"
  local json='{"tool_input":{"command":"'"$cmd"'"},"tool_name":"Bash","hook_event_name":"PreToolUse","cwd":"'"$cwd"'"}'
  echo "$json" | bash "$HOOK" 2>/dev/null || true
}

assert_blocked() {
  local name="$1" cmd="$2" cwd="$3"
  local out
  out=$(run_hook "$cmd" "$cwd")
  if echo "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null | grep -q '^deny$'; then
    echo "  PASS: $name"; pass=$((pass + 1))
  else
    echo "  FAIL: $name — expected deny, got: $out"; fail=$((fail + 1))
  fi
}

assert_passthrough() {
  local name="$1" cmd="$2" cwd="$3"
  local out
  out=$(run_hook "$cmd" "$cwd")
  if [ -z "$out" ]; then
    echo "  PASS: $name"; pass=$((pass + 1))
  else
    echo "  FAIL: $name — expected pass-through (no output), got: $out"; fail=$((fail + 1))
  fi
}

# Temp repos: one jj (with a subdir), one pure-git.
JJ_DIR=$(mktemp -d); mkdir -p "$JJ_DIR/.jj" "$JJ_DIR/sub/deep"
GIT_DIR=$(mktemp -d); mkdir -p "$GIT_DIR/.git" "$GIT_DIR/src"
trap 'rm -rf "$JJ_DIR" "$GIT_DIR"' EXIT

echo "=== jj repo: raw git is blocked ==="
assert_blocked "git status at jj root"      "git status"            "$JJ_DIR"
assert_blocked "git status in jj subdir"    "git status"            "$JJ_DIR/sub/deep"
assert_blocked "git commit at jj root"      "git commit -m x"       "$JJ_DIR"
assert_blocked "git config (internals)"     "git config user.name x" "$JJ_DIR"
assert_blocked "git rev-parse (internals)"  "git rev-parse HEAD"    "$JJ_DIR"

echo "=== jj repo: interop seams and non-git pass through ==="
assert_passthrough "jj git push allowed"    "jj git push"           "$JJ_DIR"
assert_passthrough "gh allowed"             "gh pr list"            "$JJ_DIR"
assert_passthrough "non-git command"        "ls -la"               "$JJ_DIR"

echo "=== non-jj repo: git is allowed ==="
assert_passthrough "git status in git root"   "git status"          "$GIT_DIR"
assert_passthrough "git status in git subdir" "git status"          "$GIT_DIR/src"
assert_passthrough "git commit in non-jj"     "git commit -m x"     "$GIT_DIR"
assert_passthrough "git config in non-jj"     "git config user.name x" "$GIT_DIR"

echo "=== drift-guard: all three copies are byte-identical ==="
uniq_hashes=$( (cd "$REPO_ROOT" && shasum -a 256 $COPIES) | awk '{print $1}' | sort -u | grep -c . )
if [ "$uniq_hashes" = "1" ]; then
  echo "  PASS: block-raw-git.sh copies share one sha256"; pass=$((pass + 1))
else
  echo "  FAIL: block-raw-git.sh copies have diverged:"; fail=$((fail + 1))
  (cd "$REPO_ROOT" && shasum -a 256 $COPIES)
fi

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
```

- [ ] **Step 2: Run the test to confirm it fails (red)**

Run: `bash plugins/project-setup-jj/tests/test-block-raw-git.sh`
Expected: FAIL. The three "non-jj repo: git is allowed" cases fail (the current hook has no gate, so it blocks git regardless of cwd → output present, not empty), and "drift-guard" fails (the three copies currently differ). The jj-repo blocking cases already pass.

- [ ] **Step 3: Add the jj-repo gate to the canonical copy**

In `plugins/project-setup-jj/scripts/block-raw-git.sh`, insert the gate immediately after the `input=$(cat)` line (currently line 6), before `command=$(echo "$input" | jq ...)`:

```bash
input=$(cat)

# Gate on jj-repo presence (#45). This hard wall is intended only inside a jj
# repo. Installed at the user (global) level the hook fires in every project,
# and blocking git in a non-jj project is collateral damage, not the design.
# Detect a .jj directory at cwd or any ancestor; if absent, pass through so git
# is allowed. bash 3.2-safe: no globstar, no associative arrays.
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] || cwd="$PWD"
jj_repo=false
dir="$cwd"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
  if [ -d "$dir/.jj" ]; then
    jj_repo=true
    break
  fi
  dir=$(dirname "$dir")
done
[ "$jj_repo" = true ] || exit 0

command=$(echo "$input" | jq -r '.tool_input.command // ""')
```

Leave the rest of the file (the `has_raw_git` and `has_git_internals` logic) unchanged.

- [ ] **Step 4: Sync the other two copies to the canonical one**

Overwrite both lagging copies with the canonical file so all three are byte-identical (this backports the `has_git_internals` block, the `remotes`→`remote` typo fix, the `jj plugins`→`jj repos` wording, and the new gate in one move):

```bash
cp plugins/project-setup-jj/scripts/block-raw-git.sh plugins/commit-commands-jj/scripts/block-raw-git.sh
cp plugins/project-setup-jj/scripts/block-raw-git.sh plugins/peer-review-jj/scripts/block-raw-git.sh
```

- [ ] **Step 5: Run the test to confirm it passes (green)**

Run: `bash plugins/project-setup-jj/tests/test-block-raw-git.sh`
Expected: PASS (`0 failed`). All jj-repo blocks hold, all non-jj pass-throughs hold, drift-guard reports one shared sha256.

- [ ] **Step 6: Verify byte-identity directly**

Run: `shasum -a 256 plugins/commit-commands-jj/scripts/block-raw-git.sh plugins/peer-review-jj/scripts/block-raw-git.sh plugins/project-setup-jj/scripts/block-raw-git.sh`
Expected: three identical hashes.

- [ ] **Step 7: Bump the three plugin versions**

Edit each manifest's `version` string:
- `plugins/commit-commands-jj/.claude-plugin/plugin.json`: `"0.1.0"` → `"0.1.1"`
- `plugins/peer-review-jj/.claude-plugin/plugin.json`: `"0.1.1"` → `"0.1.2"`
- `plugins/project-setup-jj/.claude-plugin/plugin.json`: `"0.1.1"` → `"0.1.2"`

- [ ] **Step 8: Verify the version-bump lint is satisfied**

Run:
```bash
CHANGED_FILES="$(printf '%s\n' \
  plugins/commit-commands-jj/scripts/block-raw-git.sh \
  plugins/peer-review-jj/scripts/block-raw-git.sh \
  plugins/project-setup-jj/scripts/block-raw-git.sh \
  plugins/project-setup-jj/tests/test-block-raw-git.sh)" \
BASE_DIR="" \
bash .github/scripts/require-version-bump.sh; echo "exit=$?"
```
Expected: `exit=0` (with `BASE_DIR=""` every touched plugin is treated as new, which passes; this is a smoke check that the script runs clean — the real base-ref comparison happens in CI).

- [ ] **Step 9: Commit (jj)**

```bash
jj describe -m "fix(#45): gate block-raw-git on jj-repo presence; unify the three copies

Walk up from cwd for a .jj directory; pass through (allow git) when absent, so
the hook is safe to install at user scope. Sync commit-commands-jj and
peer-review-jj to project-setup-jj's superset (git-internals block + wording +
typo fix) so all three are byte-identical, guarded by a new drift test."
jj new
```

---

## Task 2: #70 — fail closed on malformed input in `permission-gate.sh`

**Files:**
- Modify: `plugins/permission-gateway/tests/test-permission-gate.sh` (append a fail-closed section before the summary at line 353)
- Modify: `plugins/permission-gateway/scripts/permission-gate.sh` (insert `ERR` trap between the shebang and `set -euo pipefail`)
- Modify: `plugins/permission-gateway/.claude-plugin/plugin.json` (0.1.0→0.1.1)

**Interfaces:**
- Consumes: the same PreToolUse payload on stdin.
- Produces: on any uncaught error (e.g. unparseable JSON, or a Tier-2 command whose metacharacters break the prompt `sed`), the script now emits an `ask` decision and `exit 0` instead of exiting non-zero with no output.

- [ ] **Step 1: Write the failing tests**

In `plugins/permission-gateway/tests/test-permission-gate.sh`, insert this block immediately before the `# ---- Summary ----` line (currently line 353), reusing the existing `pass`/`fail` counters and `assert_decision` helper:

```bash
echo ""
echo "=== #70: fail-closed on malformed / unparseable input ==="

# run_gate builds valid JSON, so it cannot exercise the malformed path. Feed
# raw stdin directly instead.
run_gate_raw() {
  printf '%s' "$1" | bash "$GATE" 2>/dev/null || true
}

assert_raw_ask() {
  local test_name="$1" raw="$2"
  local output
  output=$(run_gate_raw "$raw")
  if echo "$output" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null | grep -q '^ask$'; then
    echo "  PASS: $test_name"; pass=$((pass + 1))
  else
    echo "  FAIL: $test_name — expected fail-closed ask, got: $output"; fail=$((fail + 1))
  fi
}

# Unparseable / wrong-shape input must fail CLOSED (ask), not open (silent).
assert_raw_ask "malformed: not json"       'not json at all'
assert_raw_ask "malformed: truncated json" '{"tool_input":}'
assert_raw_ask "wrong-shape: array"        '[1,2,3]'
assert_raw_ask "wrong-shape: bare number"  '42'

# Tier-2 command with a bare `|`: the prompt sed `s|{{COMMAND}}|$command|g`
# breaks on the extra delimiter. Today that path fails OPEN; the trap must turn
# it into fail-closed ask — never approve/deny. This is the case the four clean
# decision paths below would miss.
assert_decision "tier2 metachar pipe" "frobnicate a|b" "ask"

# The clean decision paths must be UNCHANGED — the trap must not misfire.
assert_decision "no-misfire: deny path"    "rm -rf /"      "deny"
assert_decision "no-misfire: ask path"     "git push origin main" "ask"
assert_decision "no-misfire: approve path" "ls -la"        "silent"
assert_decision "no-misfire: tier2 clean"  "htop"          "ask"
```

- [ ] **Step 2: Run the test to confirm it fails (red)**

Run: `bash plugins/permission-gateway/tests/test-permission-gate.sh`
Expected: FAIL. The four `assert_raw_ask` cases and `tier2 metachar pipe` fail — the current script exits non-zero with empty stdout on those inputs (fail-open), so no `ask` is emitted. The four `no-misfire` cases already pass (they exercise the current behavior, which the fix must preserve).

- [ ] **Step 3: Add the fail-closed ERR trap**

In `plugins/permission-gateway/scripts/permission-gate.sh`, replace the first two lines:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

with:

```bash
#!/usr/bin/env bash

# Fail-closed (#70): a crashed gate must not be a bypass. Mirrors the ERR trap
# in gate-config-writes.sh so the two hooks agree. On any uncaught error, emit
# `ask`. Parity + defense-in-depth: Claude Code builds the hook payload, so the
# malformed-input path is likely unreachable here — this is consistency with
# the sibling gate, not the patch of a demonstrated hole. The trap can only ever
# emit `ask`, never approve/deny, so it cannot loosen a decision.
trap 'cat <<EREOF
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "ask",
    "permissionDecisionReason": "Permission gateway: permission-gate encountered an error and is failing closed. Human approval required."
  }
}
EREOF
exit 0' ERR

set -euo pipefail
```

Leave the rest of the script unchanged.

- [ ] **Step 4: Run the test to confirm it passes (green)**

Run: `bash plugins/permission-gateway/tests/test-permission-gate.sh`
Expected: PASS (`0 failed`). Malformed/wrong-shape/metachar inputs now return `ask`; every clean decision path is unchanged.

- [ ] **Step 5: Manually re-verify the original fail-open probe from the issue**

Run:
```bash
printf 'not json at all' | bash plugins/permission-gateway/scripts/permission-gate.sh; echo "exit=$?"
```
Expected: prints the `ask` JSON and `exit=0` (was: exit 5, no output).

- [ ] **Step 6: Bump the plugin version**

Edit `plugins/permission-gateway/.claude-plugin/plugin.json`: `"version": "0.1.0"` → `"0.1.1"`.

- [ ] **Step 7: Update the stale suite-count comment**

In `.github/workflows/test.yml`, the comment on line ~37 reads "This repo has seven suites". Task 1 added an eighth. Change `seven` → `eight` so the comment stays honest. (This file is under `.github`, not `plugins/`, so it triggers no version-bump lint.)

- [ ] **Step 8: Run the full suite set the way CI does**

Run:
```bash
for t in $(find plugins .github -path '*/tests/test-*.sh' | sort); do
  echo "== $t =="; bash "$t" >/dev/null && echo PASS || echo FAIL
done
```
Expected: every suite prints `PASS` (identities depend on `~/.config/jj/config.toml`, present locally).

- [ ] **Step 9: Commit (jj)**

```bash
jj describe -m "fix(#70): fail closed on malformed input in permission-gate

Mirror gate-config-writes.sh's ERR trap so the primary gate emits ask instead
of exiting non-zero with no output (which does not block) on unparseable input.
Parity + defense-in-depth; the trap only ever emits ask, and it also closes a
latent Tier-2 sed fail-open. Tests cover malformed/wrong-shape/metacharacter
input and assert the clean decision paths do not misfire."
jj new
```

---

## Self-Review

**Spec coverage:**
- #45 jj-repo gating (§ Detection) → Task 1, Steps 3.
- #45 sync three copies to superset (§ Reconciliation) → Task 1, Steps 4, 6.
- #45 drift-guard + behavior tests (§ Testing, `.cwd` injection note) → Task 1, Step 1.
- #45 fail-open-on-inconclusive-cwd (§ Detection) → encoded in the `[ -n "$cwd" ] || cwd="$PWD"` + `|| exit 0` of Step 3; no separate task.
- #70 ERR trap (§ Fix) → Task 2, Step 3.
- #70 corrected no-misfire proof incl. Tier-2 metacharacter case (§ Testing) → Task 2, Step 1.
- #70 reachability caveat in-source → Task 2, Step 3 comment.
- Version bumps (§ Version bumps) → Task 1 Step 7, Task 2 Step 6.
- Out-of-scope items (README nit, latent Tier-2 sed bug) → deliberately not implemented; sed bug noted in Task 2 Step 1 comment.

**Placeholder scan:** none — every step has literal code, exact paths, and expected output.

**Type/name consistency:** helper names (`run_hook`/`assert_blocked`/`assert_passthrough` in Task 1; `run_gate_raw`/`assert_raw_ask` reusing existing `run_gate`/`assert_decision`/`pass`/`fail` in Task 2) are consistent within each suite. `HOOK`/`GATE` variables match their suites. Version strings match the Global Constraints table.

**One residual watch-item for the implementer:** in Task 1 Step 1, `shasum -a 256 $COPIES` relies on word-splitting `$COPIES` on newlines — intentional and bash 3.2-safe; keep it unquoted.
