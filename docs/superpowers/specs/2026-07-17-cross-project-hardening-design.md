# Cross-project hardening: jj-repo gating + fail-closed gate (#45, #70)

**Status:** approved, pre-implementation
**Date:** 2026-07-17
**Issues:**
- #45 — "Raw .git block bans Claude from using git. Even though project is not using jj"
- #70 — "permission-gateway: permission-gate.sh fails open on malformed input; gate-config-writes.sh fails closed"

**Theme:** both changes harden the layer other projects and other agents depend on. #45 removes install friction so the plugins are usable at the user (global) level; #70 closes a fail-open asymmetry in the primary permission gate. They are independent (different files, different plugins) but scoped and shipped together as one Tier-1 unit.

---

## § #45 — gate `block-raw-git.sh` on jj-repo presence

### Problem

The jj plugins install a `PreToolUse`/`Bash` hook (`block-raw-git.sh`) that denies raw `git` commands and hands back the jj equivalent. Per the README (#92), this is deliberate: a **hard wall**, not a reminder — enforcement below the level an LLM can rationalize past.

The wall is correct **inside a jj repo**. The friction is entirely **collateral damage of a user-level (global) install**: once the hook is registered globally it fires in *every* project, including git-only ones, banning git where jj was never chosen. That is the whole of #45 — not "the wall is too strong" but "the wall stands in rooms that have no jj."

### Invariant to enforce

> `block-raw-git.sh` blocks git **only when the invocation is inside a jj repo**
> (a `.jj` directory exists at cwd or any ancestor). Outside a jj repo it is a
> silent pass-through (`exit 0`, no output → git allowed).

This preserves the hard wall everywhere it is meant to stand and removes it only where it was never meant to be.

### Why `.jj` presence is the correct signal

- A jj repo — colocated or not — always has a `.jj/` directory at its workspace root. Secondary workspaces have one too.
- A **colocated** repo (`jj git init --colocate`) has **both** `.jj/` and `.git/`. Detecting `.jj` correctly still blocks git there — which is right, because colocation is a choice to live in jj. This is why `.jj` presence, not `.git` absence, is the discriminator.
- A pure git repo has only `.git/`, no `.jj/` → git allowed.

### Detection (bash 3.2-safe, dependency-free)

Inserted **after `input=$(cat)`** reads stdin (line 6), before any blocking logic — the snippet consumes `$input`, so placing it above that read would leave `$input` empty and silently fall back to the hook process's `$PWD`, which need not equal the payload cwd:

```bash
cwd=$(echo "$input" | jq -r '.cwd // ""')
[ -n "$cwd" ] || cwd="$PWD"
jj_repo=false
dir="$cwd"
while [ -n "$dir" ] && [ "$dir" != "/" ]; do
  [ -d "$dir/.jj" ] && { jj_repo=true; break; }
  dir=$(dirname "$dir")
done
[ "$jj_repo" = true ] || exit 0   # not a jj repo → allow git
```

- Reads `.cwd` from the same hook payload the sibling `permission-gate.sh` already consumes, so cwd is available to us.
- Walks up ancestors so a command run from a subdirectory of the repo still detects `.jj` at the root.
- No `jj` binary, no globstar, no associative arrays — runs under macOS bash 3.2 (the test-suite floor) and ubuntu bash 5.

**Inconclusive-cwd behavior (deliberate, flag for review):** if `.cwd` is empty *and* the `$PWD` fallback yields no `.jj` on the walk, the script errs **open** (allows git). Rationale: the entire purpose of #45 is to not block outside jj, so when jj genuinely cannot be confirmed, friction-removal wins. In practice cwd is always present for Bash `PreToolUse` hooks, so this branch is near-degenerate. It is called out here so the choice is explicit rather than accidental.

### Reconciliation: sync all three copies to the superset

`block-raw-git.sh` exists in **three** plugins. Verified by sha256:

- `commit-commands-jj` and `peer-review-jj` are **byte-identical**.
- `project-setup-jj` is a **superset**: it additionally carries a `has_git_internals` block (denies `.git/` access, `git config`, `git rev-parse`) and fixes a typo the other two carry (`jj git remotes list` → `jj git remote list`).

History (`#5`/`#14` added the superset to project-setup; the other two are unchanged since the initial commit) shows the divergence is **lag, not intentional per-plugin design** — nothing is deliberately specialized. Leaving it re-invites silent drift; that drift *is* the root cause this issue exposes.

Therefore all three become **byte-identical**, adopting project-setup's superset plus the new gate:
1. backport the `has_git_internals` block into `commit-commands-jj` and `peer-review-jj`
2. adopt project-setup's message text verbatim in those two — both the `remotes`→`remote` typo fix and the `"...not allowed in jj plugins"`→`"...in jj repos"` wording, so the deny reason is identical everywhere
3. add the jj-detection gate to all three

After this, `diff` across the three (and a shared sha256) yields zero difference.

Consequence, chosen with eyes open: `commit-commands-jj` and `peer-review-jj` **gain** the `.git/`-internals block. It only ever fires inside a real jj repo (it sits below the new gate), so it is consistent with the hard-wall philosophy and inert in git-only projects.

The gate wraps the **entire** script: when not a jj repo, neither the raw-git branch nor the internals branch runs.

### Note on self-containment

Plugins ship self-contained under `${CLAUDE_PLUGIN_ROOT}`; a single shared script across plugins is not the model. "Byte-identical" here means three copies with identical content, kept honest by the drift-guard test below — not one physical file.

---

## § #70 — fail closed on malformed input in `permission-gate.sh`

### Problem

The plugin's two hooks disagree about what a crashed gate means:

- **`gate-config-writes.sh` fails closed:** an `ERR` trap emits `ask`, with the in-source rationale *"A crashed gate should not be a bypass."*
- **`permission-gate.sh` — the primary engine — has no trap**, and runs under `set -euo pipefail`. On any input `jq` cannot parse, the pipeline fails, the script exits non-zero with **no output**, and a `PreToolUse` hook that exits non-zero with no output **does not block** — so every Tier-1 deny (`rm -rf /`, `sudo`, force-push), the `.local.md` rules, and Tier-2 escalation are all silently skipped.

The README frames the deny tier as an immutable floor against a file-based prompt-injection path. An input the gate cannot parse goes *around* the floor without touching `.local.md` at all: the ratchet holds; the input path bypasses it.

### Reachability caveat (recorded, not assumed away)

Claude Code constructs the hook payload itself, so the malformed-JSON path may be **unreachable in practice**. This fix is therefore **parity + defense-in-depth**, not the patch of a demonstrated live hole — and the source comment says exactly that, so no one later mistakes it for evidence the hole was reachable. The value is that the two gates stop disagreeing, and the primary gate's failure mode becomes the safe one.

### Fix

Mirror the exact construct from `gate-config-writes.sh` into `permission-gate.sh`, installed **after the shebang and before `set -euo pipefail`**, emitting `ask` on any uncaught error:

```bash
#!/usr/bin/env bash

# Fail-closed: a crashed gate must not be a bypass. Mirrors the ERR trap in
# gate-config-writes.sh so the two hooks agree. Parity + defense-in-depth:
# Claude Code builds the hook payload, so malformed input is likely
# unreachable here — this is consistency with the sibling gate, not the patch
# of a demonstrated hole.
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

The trap fires on the malformed-input path (`command=$(echo "$input" | jq -r …)` returns non-zero under errexit → ERR) and turns a silent bypass into `ask`.

### The real work: prove no misfire

The trap must not produce a **wrong-direction** decision (never a spurious `approve`/`deny`, and no `ask` on a command that would otherwise cleanly `approve`). The precise invariant, corrected after empirical review:

> Every non-zero return in the script is **either** a `grep -q` no-match inside an `if` condition (exempt from `set -e`) and `check_local_rules … || true`, **or** it falls into the trap and emits `ask`. The trap can only ever emit `ask` — never `approve` or `deny` — so it cannot loosen a decision.

The earlier framing ("*all* normal non-zero returns are `grep -q` in `if`s") was too strong. There is at least one non-grep failure source: the Tier-2 block runs `prompt_with_command=$(echo "$prompt_template" | sed "s|{{COMMAND}}|$command|g")`, and `sed`'s `|` delimiter breaks when `$command` contains a bare `|` (e.g. `a | b`). **Today that path already fails open** (exit 1, empty stdout → non-blocking); under the trap it becomes fail-closed `ask`. So the trap *improves* a latent Tier-2 fail-open — but it means the trap genuinely can fire on a real command, and the test set must cover that, not just the four clean paths. **This must be demonstrated by test, not assumed.**

(The latent Tier-2 `sed`-delimiter bug is noted but **not fixed here** — the trap makes its failure safe, and fixing the substitution itself is out of scope for #70. Worth a separate issue.)

---

## § Testing

### New: `test-block-raw-git.sh`

No test currently covers `block-raw-git.sh`. The new suite (bash 3.2-safe, matching the existing suites' harness) asserts:

1. `git status` is **blocked** when a `.jj` directory is present (at cwd and at an ancestor of cwd).
2. `git status` **passes through** (exit 0, no output) when no `.jj` exists on the walk.
3. `jj git push` and `gh …` are allowed regardless (the deliberate interop seams).
4. the `has_git_internals` branch fires inside a jj repo (`.git/` access, `git config`, `git rev-parse`).
5. **drift-guard:** all three copies share one sha256 — so the three cannot silently re-diverge. This directly closes the root cause.

Placement: `project-setup-jj/tests/` (the canonical superset source); the drift-guard reads the other two copies by repo-relative path.

**Harness note:** the existing `test-permission-gate.sh` `run_gate` helper builds payloads with **no `.cwd`** field. block-raw-git detection is cwd-driven, so the new suite cannot reuse that harness verbatim — each case must inject a `.cwd` pointing at a temp directory that does (or does not) contain `.jj`, created in the test's setup.

### Extend: `test-permission-gate.sh`

- malformed-JSON input (e.g. `not json`, `{"tool_input":}`) → asserts `ask` is emitted (exit 0 **with** the fail-closed JSON), i.e. the fix works.
- wrong-shape valid JSON (e.g. `[1,2,3]`, `42`) → asserts fail-closed `ask` (desired, not a misfire).
- regression across the clean decision paths (deny `rm -rf /` / ask `git push` / approve `ls` / a novel Tier-2 command) → asserts each still returns its own decision and the trap does **not** override it.
- **Tier-2 command containing shell metacharacters** (a bare `|`, and backticks) → this is the path the corrected mechanism identifies; asserts it resolves to `ask` (fail-closed) and never to `approve`/`deny`. The four clean paths above would miss this — it is a required case, not optional.

---

## § Version bumps (CI-mandatory, #84)

CI fails **red** on any change under `plugins/<name>/` without a version bump, because the plugin cache is keyed by version string. Required bumps:

| Plugin | From | To | For |
|---|---|---|---|
| `commit-commands-jj` | 0.1.0 | 0.1.1 | #45 |
| `peer-review-jj` | 0.1.1 | 0.1.2 | #45 |
| `project-setup-jj` | 0.1.1 | 0.1.2 | #45 |
| `permission-gateway` | 0.1.0 | 0.1.1 | #70 |

---

## § Out of scope

- The README lists `workspace-jj` among the plugins carrying `block-raw-git.sh`, but that plugin ships no such hook. A documentation nit, tracked separately — not fixed here.
- Broader deduplication of the three copies into a shared mechanism: contrary to the per-plugin self-containment model; the drift-guard test is the chosen safeguard instead.
- The latent Tier-2 `sed "s|{{COMMAND}}|$command|g"` delimiter bug (breaks on commands containing a bare `|`). #70's trap makes its failure safe (fail-closed `ask`); fixing the substitution itself — e.g. a delimiter unlikely to appear in commands, or a different templating approach — is a separate issue.

---

## § Files touched

**#45**
- `plugins/commit-commands-jj/scripts/block-raw-git.sh` — gate + backport superset
- `plugins/peer-review-jj/scripts/block-raw-git.sh` — gate + backport superset
- `plugins/project-setup-jj/scripts/block-raw-git.sh` — gate
- `plugins/project-setup-jj/tests/test-block-raw-git.sh` — new suite + drift-guard
- three `plugin.json` version bumps

**#70**
- `plugins/permission-gateway/scripts/permission-gate.sh` — ERR trap
- `plugins/permission-gateway/tests/test-permission-gate.sh` — malformed + non-misfire cases
- `plugins/permission-gateway/.claude-plugin/plugin.json` — version bump
