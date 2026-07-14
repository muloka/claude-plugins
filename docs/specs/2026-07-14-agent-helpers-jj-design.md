# agent-helpers-jj — jj query helpers for agents (design)

**Date:** 2026-07-14
**Status:** Implemented (reduced to four helpers during execution — see Revision).

> **Revision (2026-07-14, during implementation):** reduced from six helpers to **four**. TDD proved that `--ignore-working-copy` makes a helper read jj's *last snapshot*, not live disk edits, so the two working-copy helpers (`jjclean`, `jjfiles`) return stale "am I clean / what changed?" answers. They were cut. The four shipped helpers — `jjctx`, `jjstack`, `jjconflicts`, `jjcheckpoint` — query committed / op-log state where the flag is strictly correct. The allowlist is correspondingly four values (`Bash(jjctx:*)`, `Bash(jjstack:*)`, `Bash(jjconflicts:*)`, `Bash(jjcheckpoint:*)`). Sections below that say "six" reflect the original design; the code is authoritative.

## Goal

Give agents (and their subagents) a small set of **read-only jj query shortcuts** that bake in `--ignore-working-copy`, so concurrent-workspace fan-flames runs never race on the working-copy snapshot lock. The flag is the one thing agents reliably get wrong — the natural form (`jj log -r @ -T json`) omits it, and the resulting snapshot race is non-obvious and non-local. A wrapper *guarantees* the flag where prose guidance only suggests it.

This is deliberately scoped to the **correctness core**. Mutation wrappers, workspace helpers, and a `jjhelp` catalog were considered and cut (see Non-Goals): they compete with the agent's existing jj fluency and lose, and add discovery + permission surface for little gain.

## Scope decision (why this shape)

From an agent's perspective, alias layers over a command language the agent already speaks are mostly negative value — indirection to learn and verify against a thing it can already write. The exception is discipline the agent can't easily self-correct: `--ignore-working-copy` on read-only queries in a concurrent context. So the library is exactly the read-only queries where that flag matters, and nothing else.

## Architecture

A **new, single-purpose plugin: `agent-helpers-jj`**, owning everything machine-level.

Rationale: the install is machine-level (writes under `$HOME`), whereas `project-setup-jj` is purely project-scoped — every one of its writes targets `$(jj root)/.claude/…`; its only `~/` references are read-only plugin-cache paths. An audit confirmed nothing in `project-setup-jj` is machine-level, so **nothing moves out of it**. Putting a global installer inside a project-scoped plugin would be the sole exception to that plugin's clean identity, so the helpers get their own home. This also matches the repo's aesthetic of small, single-purpose jj plugins, and lets a user install *just* the helpers.

### Files

```
plugins/agent-helpers-jj/
  .claude-plugin/plugin.json                     # manifest (repo convention: under .claude-plugin/)
  README.md
  LICENSE
  scripts/jj-agent-helpers.sh                    # the six functions + _jjq
  commands/agent-helpers-setup.md                # machine-level install
  commands/agent-helpers-remove.md               # idempotent uninstall
  templates/jj-agent-helpers-claudemd.md         # the inline CLAUDE.md catalog snippet
  tests/
    test-jj-agent-helpers.sh                     # unit: the six functions in a scratch repo
    test-agent-helpers-install.sh                # installer: setup→setup→remove against a fake $HOME
```

Plus an entry in the repo marketplace manifest `./.claude-plugin/marketplace.json` registering the new plugin.

### Runtime dependency: the shell snapshot (must be documented for users)

The agent's Bash tool runs a non-interactive shell that replays a Claude Code **shell snapshot** (`~/.claude/shell-snapshots/snapshot-*.sh`), regenerated at session start. A function added to `~/.zshrc` becomes callable by the agent **only after the next session regenerates the snapshot** — i.e. after a restart. So `agent-helpers-setup` must tell the user, prominently: *the helpers (and their prompt-free allowlist) take effect only after you restart Claude Code / start a new session.* Without a restart, `jjctx` is both "command not found" and un-allowlisted — a baffling double failure if undocumented. (This same mechanism is what makes the permission claim below hold: the matcher sees the literal token `jjctx` replayed from the snapshot, not the expanded `jj …`.)

## Components

### 1. `scripts/jj-agent-helpers.sh` — the function library

Target shell: **zsh** (the source line is added to `~/.zshrc`; bash support is a Non-Goal for v1). A private `_jjq` backs every function so the `--ignore-working-copy` flag exists in exactly one place.

```zsh
# _jjq: read-only jj — never snapshots the working copy; safe under concurrent workspaces.
_jjq() { jj --ignore-working-copy "$@"; }

# jjctx — current change as JSON (orientation)
jjctx()   { _jjq log -r @ --no-graph -T 'json(self) ++ "\n"'; }

# jjstack — local changes ahead of trunk, JSON lines
jjstack() { _jjq log -r 'trunk()..@' --no-graph -T 'json(self) ++ "\n"'; }

# jjfiles [rev] — changed files in <rev|@> as JSON {path,status}
jjfiles() { _jjq diff -r "${1:-@}" -T '"{ \"path\": " ++ self.path().display().escape_json() ++ ", \"status\": " ++ self.status().escape_json() ++ " }\n"'; }

# jjclean — exit 0 if the working copy has no changes (a commit/verification gate)
jjclean() { [[ "$(_jjq log -r @ --no-graph -T 'if(empty,"1","0")')" == 1 ]]; }

# jjconflicts — exit 0 if clean; 1 (+ prints files) if conflicts; >1 on a real error.
# On jj 0.43, `jj resolve --list` exits 0 (and lists) when conflicts exist, and exits 2
# with "No conflicts found…" when clean. We distinguish that from other failures (not a
# jj repo, jj missing) so an agent's pre-commit gate can't read "clean" from a broken env.
# The plan MUST re-verify the exit codes on the target jj version before relying on them.
jjconflicts() {
  local out rc
  out="$(_jjq resolve --list 2>/dev/null)"; rc=$?
  if (( rc == 0 )); then
    [[ -z "$out" ]] && return 0        # no conflicts listed
    print -r -- "$out"; return 1        # conflicts present
  fi
  (( rc == 2 )) && return 0            # "No conflicts found" — clean
  print -r -- "jjconflicts: jj error (rc=$rc)" >&2; return "$rc"   # real failure — surfaced
}

# jjcheckpoint — current operation id (for a fan-flames ledger start-op)
jjcheckpoint() { _jjq op log -n1 --no-graph -T 'id.short()'; }
```

All six templates are verified working against jj 0.43. Contract per function: JSON on stdout (`jjctx`/`jjstack`/`jjfiles`/`jjcheckpoint`) or a meaningful exit code (`jjclean`, `jjconflicts`).

### 2. `commands/agent-helpers-setup.md` — machine-level install

A one-time, per-machine, **consent-gated, idempotent** install. It writes to three files under `$HOME` plus one script — so it presents **one consent prompt listing all four targets** (`~/.zshrc`, `~/.claude/CLAUDE.md`, `~/.claude/settings.json`, `~/.config/jj-agent-helpers/`) before touching anything. On decline, it prints exactly what the user would need to add by hand and makes no changes. The four steps, each reversible:

1. **Copy the script** → `~/.config/jj-agent-helpers/jj-agent-helpers.sh` (stable path; re-copied on re-run / plugin update). `mkdir -p` the dir.
2. **Source line in `~/.zshrc`** — add the fenced block idempotently (replace in place if the fence already exists; append otherwise). If `~/.zshrc` doesn't exist, create it.
3. **CLAUDE.md catalog** → write the fenced snippet from `templates/jj-agent-helpers-claudemd.md` into `~/.claude/CLAUDE.md` (replace the fence in place if present; append otherwise). Create the file (and `~/.claude/`) if absent.
4. **Permission allowlist** → add the six helper entries to `permissions.allow` in `~/.claude/settings.json` via `jq`, deduped. The filter MUST tolerate a missing file and a missing key — `(.permissions.allow // [])`, then rebuild `.permissions.allow` as the deduped union. Create `settings.json` as `{"permissions":{"allow":[...]}}` if absent. Pattern form: colon-star (`Bash(jjctx:*)`, …) — tighter than the repo's existing glob form (`Bash(jj log*)`, which would also match `jjctxfoo`). **The plan must confirm the no-arg case (`jjctx` with no arguments) actually auto-approves under colon-star; if it surprisingly requires an argument, fall back to the exact form `Bash(jjctx)` for the five no-arg helpers and colon-star only for `jjfiles`.**

Before sourcing, the command checks whether any of the seven names (`_jjq`, `jjctx`, `jjstack`, `jjfiles`, `jjconflicts`, `jjcheckpoint`, `jjclean`) already exist as a function or alias in the user's shell, and warns about any collision (the source would shadow the user's own). It verifies `jj` is available, and ends by reporting a summary of what changed **and reminding the user to restart Claude Code** (see Runtime dependency above).

### 3. `commands/agent-helpers-remove.md` — uninstall

Reverses all four steps idempotently: delete the fenced block from `~/.zshrc` and `~/.claude/CLAUDE.md`, filter the six known values out of `~/.claude/settings.json` via `jq`, and remove `~/.config/jj-agent-helpers/jj-agent-helpers.sh` (optionally the now-empty dir). Safe to run when nothing is installed.

### 4. Marker conventions (identifiable / reversible)

Each home file gets a distinct, greppable marker; the scheme differs because two files allow comments and one doesn't.

**`~/.zshrc`** — sentinel comment fence (conda-style):
```zsh
# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>
source ~/.config/jj-agent-helpers/jj-agent-helpers.sh
# <<< jj-agent-helpers <<<
```

**`~/.claude/CLAUDE.md`** — HTML-comment fence (invisible when rendered, still greppable):
```markdown
<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->
**jj query helpers** (run in jj repos; all use `--ignore-working-copy`, safe under concurrent workspaces):
`jjctx` current change (one JSON object) · `jjstack` local changes vs trunk (JSONL) · `jjfiles [rev]` changed files (JSONL) · `jjconflicts` (exit 0 = clean) · `jjcheckpoint` op id · `jjclean` (exit 0 = nothing to commit)
<!-- END jj-agent-helpers -->
```

**`~/.claude/settings.json`** — JSON has no comments, so no fence. The six entries in `permissions.allow` are **self-identifying by value** — `Bash(jjctx:*)`, `Bash(jjstack:*)`, `Bash(jjfiles:*)`, `Bash(jjconflicts:*)`, `Bash(jjcheckpoint:*)`, `Bash(jjclean:*)`. Setup adds each only if absent (dedupe); remove filters exactly those six out. Both operations use `jq` so the rest of the file is untouched.

**Exact insertion bytes.** The plan must pin the exact fence bytes — each fenced block is preceded by exactly one blank line (unless the file is empty/new) and the block itself has no trailing blank line — so re-run replacement is exact and remove restores the two *text* files byte-clean. The BEGIN/END fence means re-run **blindly replaces** the CLAUDE.md block; this deliberately omits the `hash:<hex>` update-detection marker that `project-setup-jj`'s `CLAUDE.md.template` uses. That's an intentional divergence (the block is small and always safe to overwrite), noted here so a reviewer doesn't read it as an oversight.

What the markers buy: idempotent setup (no accumulating duplicate blocks), surgical remove (deletes exactly what the plugin owns), and human auditability (`grep jj-agent-helpers ~/.zshrc ~/.claude/CLAUDE.md`; the "managed by agent-helpers-jj" tag names the source).

## Why the allowlist is load-bearing (not polish)

The Bash permission matcher evaluates the *typed* command string (`jjctx`), not the expanded `jj --ignore-working-copy log …`. So helper names are opaque to any existing `Bash(jj …)` allowlist. `project-setup-jj` already allowlists `Bash(jj log*)` etc., so raw `jj log` runs **prompt-free today** — but an un-allowlisted `jjctx` would *prompt*, and the agent would fall back to raw jj, losing the `--ignore-working-copy` enforcement that is the feature's entire reason to exist. Step 4 (allowlisting the six read-only helpers) is therefore required for the feature to work, not a convenience. The helpers are read-only and side-effect-free, so auto-approving them is safe.

## Discoverability

No `jjhelp`. With six functions used regularly by a fan-flames orchestrator, the earlier trade analysis favors **inlining the catalog** in `~/.claude/CLAUDE.md` over a `jjhelp` indirection (jjhelp wins for large, occasionally-used catalogs; inline wins for a small, frequently-used set). The inline catalog is the CLAUDE.md fenced block above.

## Testing

Two bash harnesses, in the style of `project-setup-jj/tests/test-statusline-jj.sh`.

**`tests/test-jj-agent-helpers.sh` — unit tests for the functions.** Creates a scratch jj repo, sources `jj-agent-helpers.sh`, and asserts:

- `jjctx` emits a JSON object containing the current `change_id`.
- `jjstack` emits JSON lines for changes ahead of trunk. **The harness must create a `main`/trunk bookmark at `@` first** (as `test-statusline-jj.sh` sets up `main@origin`) — in a fresh repo `trunk()` resolves to the root commit, so `trunk()..@` is never empty and the "empty when `@` is trunk" assertion is only meaningful with a real trunk bookmark in place.
- `jjfiles` emits `{path,status}` JSON lines for a modified file.
- `jjclean` exits 0 on an empty `@`, non-zero when `@` has a diff.
- `jjconflicts` exits 0 (clean) on a conflict-free repo; the plan should also cover the broken-env path (non-jj dir → non-zero, not a false "clean").
- `jjcheckpoint` prints a short op id.
- **Race-safety invariant:** every read-only function body contains `--ignore-working-copy` (grep the script — guards against a future edit dropping the flag).
- **Drift guard:** the function names referenced in `templates/jj-agent-helpers-claudemd.md` exactly match the *public* functions defined in `jj-agent-helpers.sh` — **excluding `_jjq`**, which is a private helper intentionally absent from the catalog (a naive name-set comparison would false-fail on it).

**`tests/test-agent-helpers-install.sh` — installer idempotency + reversibility (the real risk surface).** Runs the setup and remove logic against a **fake `$HOME`** (a temp dir with a seeded `~/.zshrc`, `~/.claude/CLAUDE.md`, and `~/.claude/settings.json`), asserting:

- setup produces exactly one fenced block in each text file and the six values in `settings.json`;
- **setup run twice is a no-op** — no duplicate fences, no duplicate allowlist values;
- setup then remove leaves `~/.zshrc` and `~/.claude/CLAUDE.md` **byte-identical** to their pre-install content, and `~/.claude/settings.json` **semantically identical** (jq-normalized — see Verification note), with the script removed;
- missing-file paths: setup against an absent `~/.zshrc` / `CLAUDE.md` / `settings.json` (and a `settings.json` with no `permissions.allow` key) all succeed and produce valid results.

## Non-Goals (YAGNI)

- **Mutation wrappers** (`jjd`, `jjc`, `jjresolve`, `jjfix`, `jjrewind`) — agents are fluent in `jj describe -m`, etc.; the safe non-interactive forms are already enforced by the fan-flames dispatch-prompt guidance merged in PR #64. Near-zero agent value.
- **Fan-flames workspace helpers** (`jjws_add`, `jjws_forget`, `jjrootkey`) — `fan-flames.md` already inlines the workspace-add/forget commands with the `/tmp/jj-workspaces` convention, and the orchestrator has them in context.
- **`jjhelp` catalog** — see Discoverability; inline wins at this size.
- **Per-project function variants** and any auto-`jj root` on shell init — the functions are global by nature (sourced from `~/.zshrc`) and call `jj`, erroring harmlessly outside a jj repo.
- **bash support** (`~/.bashrc`, POSIX-only bodies) — v1 targets zsh, matching the user's shell and the plugin's install target. Revisit if there's demand.
- **Folding into `project-setup-jj`** — rejected to preserve that plugin's project-only identity.

## Verification (whole feature)

1. Both harnesses pass — `tests/test-jj-agent-helpers.sh` (functions) and `tests/test-agent-helpers-install.sh` (installer idempotency + reversibility).
2. `agent-helpers-setup` on a clean machine produces exactly the fenced blocks / known values; re-running is a no-op (no duplicates).
3. `agent-helpers-remove` restores the two **text** files (`~/.zshrc`, `~/.claude/CLAUDE.md`) **byte-identical** to their pre-install state and removes the script. `~/.claude/settings.json` is restored **semantically identical** (not byte-identical): it round-trips through `jq`, which reserializes the whole document (indentation and key order are jq's, not the original's) — only the six values are logically added/removed, the rest of the settings are preserved.
4. In a live session **after install + restart** (the restart regenerates the shell snapshot — see Runtime dependency), an agent can call `jjctx` prompt-free (allowlist working) and the call carries `--ignore-working-copy` semantics — no new working-copy snapshot is written to the shared operation log (the actual serialization point across workspaces; each workspace snapshots its own working copy, and the flag skips that op-log write).
