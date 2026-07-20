# Extract `/project-setup` install logic into a testable script (#78)

**Status:** approved, pre-implementation
**Date:** 2026-07-20
**Issue:** #78 — "/project-setup is untested and writes to a consumer's .claude/settings.json"

## Problem

`/project-setup` is the entry point for adopting these plugins in any project: it copies hook scripts into the consumer's `.claude/scripts/`, deep-merges hooks + permissions into `.claude/settings.local.json`, and installs/updates a CLAUDE.md section. It has **no test** — and its worst failure shape is unique: every other untested command fails in front of the person who ran it, but this one **writes into someone else's repo config and leaves**.

The reason it has no test is structural, not neglect: **the install logic is prose the model improvises, not code.** The command's Step 3 says *"deep-merge the following using `jq`, preserving existing keys and deduplicating"* and gives only a merge *strategy* (line 94) — never an actual `jq` invocation. So Claude reconstructs the merge every run. There is nothing to invoke, so the agent-helpers test model the issue proposes (`bash install.sh` against a fake `$HOME`) cannot apply: **there is no `install.sh`.**

This is exactly the "unexercised prose, ~5–9 defects/file" surface #78 cites. The idempotency it wants to pin (re-run without duplicates, preserve unrelated hooks) exists nowhere as code.

## Approach (Path A): extract, then test

Move every deterministic step out of the prose command and into one installer script, then test the script. This does more than add coverage — it makes consumer-config writes deterministic and deletes the "re-improvise the `jq` each run" defect class.

**Deterministic → script (Steps 2–6):** copy the four consumer hook scripts + `chmod`; deep-merge the hook and permission blocks into `settings.local.json`; the CLAUDE.md 4-case hash logic.

**Stays in the command:** Step 1's jj-repo gate + resolving the plugin root, and Step 7's user-facing summary. Everything else moves.

## Component 1 — `scripts/project-setup-install.sh`

**Interface:** `project-setup-install.sh <plugin-root> <project-root>`
- `<plugin-root>`: directory containing `scripts/` and `templates/` (the plugin cache dir; the command resolves and passes it).
- `<project-root>`: the consumer repo root (the command passes `$(jj root)`).
- **No jj calls** — pure file operations, so the script tests with plain temp dirs, no jj required. bash 3.2-safe (macOS CI floor): no globstar, no associative arrays, no `mapfile`.

**Responsibilities:**

1. `mkdir -p <project-root>/.claude/scripts`.
2. Copy the **four** consumer hook scripts from `<plugin-root>/scripts/` and `chmod +x` each: `jj-session-start.sh`, `require-jj-new.sh`, `jj-workspace-create.sh`, `jj-workspace-remove.sh`. (`block-raw-git.sh` is a plugin-registered `PreToolUse` hook, never copied into the consumer; `statusline-jj.sh` belongs to the separate statusline commands.)
3. Deep-merge into `<project-root>/.claude/settings.local.json` (create `{}` if absent), substituting absolute `<project-root>/.claude/scripts/...` command paths:
   - **`hooks.SessionStart`** — matcher `startup|resume|clear|compact` → `jj-session-start.sh`, `async: false`
   - **`hooks.PreCompact`** — `jj status >/dev/null 2>&1 || true`
   - **`hooks.PreToolUse`** — matcher `Edit|Write|NotebookEdit` → `require-jj-new.sh`
   - **`hooks.WorktreeCreate`** → `jj-workspace-create.sh`
   - **`hooks.WorktreeRemove`** → `jj-workspace-remove.sh`
   - **`permissions.allow`** — the jj allowlist + `Bash(gh *)`; **`permissions.deny`** — `Bash(git *)`

   **Merge contract (the thing #78 pins):**
   - **Managed hooks (SessionStart, PreToolUse, WorktreeCreate, WorktreeRemove) — replace by identity, at HOOK granularity (not entry granularity).** For each managed event: within every existing entry, drop from its `.hooks[]` array any hook whose `command` references our managed script path (match on the `.claude/scripts/<name>.sh` suffix); drop any entry whose `.hooks[]` becomes empty as a result; then append our current entry (matcher + our hook). Result: same version → exact no-op; changed definition on a version upgrade → old ours replaced, no stale duplicate; the user's own hooks are preserved **even when hand-merged into the same entry object as one of ours**. This granularity is load-bearing: a whole-entry filter (`map(select(...))` at entry level) would silently delete a user hook co-located in the same `.hooks[]` array as a managed one — the exact "writes into someone else's config and damages it" failure #78 exists to prevent (verified reproducible during spec review). This mirrors the CLAUDE.md hash-replace philosophy already in Step 6.
   - **PreCompact — keyed by value equality.** Its command is a fixed string with no script path to key on; append only if that exact entry isn't already present. Same effect (no duplicate on re-run).
   - **permissions.allow / deny — union-dedupe by value.** Add our entries if absent; preserve all existing.
   - **Malformed existing `settings.local.json` → abort loudly, do not overwrite.** If the file exists but is not valid JSON, exit non-zero with a clear message and touch nothing. We never clobber a file we cannot parse — the fail-safe that matters most for a tool writing into someone else's repo.
4. **CLAUDE.md** (Step 6 logic, verbatim behavior): read `<plugin-root>/templates/CLAUDE.md.template`; compute the body hash between the `jj-project-setup:start`/`:end` markers (`md5 -q` on macOS, `md5sum` on Linux — detect which is available); handle the four cases — (1) no file → create; (2) hashed marker present → skip if hash matches, else replace the marked section; (3) legacy unhashed marker → replace (upgrades to hashed); (4) no marker → prepend template + blank line, preserving all existing content.
5. **Emit a `key=value` summary to stdout** — the single source of truth for both the command's Step-7 report and the test's assertions:
   ```
   session_start=copied
   require_jj_new=copied
   workspace_hooks=copied
   settings=created|merged
   claude_md=created|updated|unchanged
   restart_required=true
   ```

## Component 2 — the shrunk command (`commands/project-setup.md`)

Reduces to:
1. **Gate:** run `jj root`; if it fails, tell the user this requires a jj repository and stop.
2. **Resolve plugin root** as `${CLAUDE_PLUGIN_ROOT}` — no "find the directory containing this command file" reasoning. This is already the proven, zero-judgment pattern in this repo: `agent-helpers-jj/commands/agent-helpers-setup.md` calls `bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-helpers-install.sh"` directly. Adopting it removes the last bit of model improvisation from the command.
3. **Run** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-setup-install.sh" "${CLAUDE_PLUGIN_ROOT}" "$(jj root)"`.
4. **Relay:** expand the `key=value` summary into the friendly Step-7 summary and the restart reminder.

The improvised-`jq` prose (Steps 2–6 bodies) is deleted; the merge/copy/CLAUDE.md details now live only in the script and its test. The maintainer note about the load-bearing CLAUDE.md hash moves to the script (or stays with the template) rather than the command.

## Component 3 — `tests/test-project-setup-install.sh`

Modeled on `test-agent-helpers-install.sh` (fake install target in `mktemp` dirs), but needs **no jj** — the script takes explicit paths. House style: `#!/usr/bin/env bash`, `set -euo pipefail`, pass/fail counters, ends `[ "$fail" -eq 0 ]`, prints `N passed, M failed`. bash 3.2-safe. **Write fail-first.** Setup fabricates a fake `<plugin-root>` (a `scripts/` dir with stub hook scripts + a `templates/CLAUDE.md.template`) and a temp `<project-root>`.

Cases:
1. **Fresh install:** all four scripts copied and executable; `settings.local.json` is valid JSON; all five hook events present with correct commands; `permissions.allow`/`deny` present; CLAUDE.md created with the hashed marker; summary lines correct (`settings=created`, `claude_md=created`).
2. **Idempotent re-run:** running twice leaves `settings.local.json` byte-identical to the first run (no duplicate hook entries); second run reports `claude_md=unchanged`.
3. **Unrelated config preserved:** pre-seed `settings.local.json` with an unrelated hook and an unrelated permission; after install both survive and ours are added.
4. **Stale-version hook replaced, not duplicated:** pre-seed a settings file containing an *old* form of one of our managed hooks (same script path, different matcher/shape); after install there is exactly one of ours, with the current shape.
5. **CLAUDE.md four cases:** no file → created; matching hash → `unchanged`, body untouched; differing hash → marked section replaced, surrounding content intact; legacy unhashed marker → upgraded; no marker → template prepended, existing content preserved.
6. **Malformed existing settings → abort, no clobber:** pre-seed invalid JSON; assert the script exits non-zero, prints a clear error, and leaves the file byte-for-byte unchanged.
7. **Co-located user hook survives (hook-granularity contract):** pre-seed a settings file where the user's own hook shares a single entry's `.hooks[]` array with one of our managed hooks; after install, our hook is refreshed **and the user's hook is still present**. This is the case a whole-entry filter would fail; it pins the hook-granularity requirement.

The test is discovered by the CI glob (`plugins/*/tests/test-*.sh`) automatically.

## Version bump (CI-mandatory, #84)

`project-setup-jj` 0.1.2 → 0.1.3.

## Out of scope

- The two statusline commands (`statusline-jj-setup`, `statusline-jj-remove`) improvise their own smaller `jq` merges. A shared merge helper could serve them too, but that is scope creep; keep the merge logic internal to `project-setup-install.sh` for now (YAGNI). Note it as a possible later extraction.
- Renaming the settings target to `settings.json`: the command uses `settings.local.json` today; this keeps that. (#78's title says `settings.json`; the body and command say `.local`. We follow the code.)
- LLM-in-the-loop evaluation of the full `/project-setup` command (Path B) belongs to the eval-suite umbrella (#79), not here.

## Files touched

- Create: `plugins/project-setup-jj/scripts/project-setup-install.sh`
- Create: `plugins/project-setup-jj/tests/test-project-setup-install.sh`
- Modify: `plugins/project-setup-jj/commands/project-setup.md` (shrink to gate → call → relay)
- Modify: `plugins/project-setup-jj/.claude-plugin/plugin.json` (0.1.2 → 0.1.3)
