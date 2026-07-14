# agent-helpers-jj Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use workspace-jj:fan-flames (per CLAUDE.md override of superpowers:subagent-driven-development) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Tasks are independent enough to review one at a time; Tasks 2–4 build on Task 1's directory.

**Goal:** Ship a new `agent-helpers-jj` plugin that installs six read-only jj query shortcuts (each wrapping `jj --ignore-working-copy …`) into the user's shell, so concurrent fan-flames workspaces never race on the working-copy snapshot / op-log.

**Architecture:** A single-purpose plugin. The six functions live in one sourced shell file. The risky part — a consent-gated, idempotent, machine-level installer that edits three `$HOME` files — is realized as a **testable shell script** (`scripts/agent-helpers-install.sh`) with `install`/`remove` subcommands, driven by thin markdown command wrappers that own consent + reporting. Everything is marker-fenced for surgical removal.

**Tech Stack:** POSIX-ish bash/zsh shell, `jq` for JSON, `jj` (Jujutsu) 0.43. No new runtime dependencies.

Design source: `docs/specs/2026-07-14-agent-helpers-jj-design.md` (read it before starting).

> **Revision (2026-07-14, during execution):** reduced from six helpers to **four**. TDD proved that under `--ignore-working-copy` a helper reads jj's *last snapshot*, not live disk edits — which makes the two working-copy helpers (`jjclean`, `jjfiles`) report stale "am I clean / what changed?" answers. They were cut; the four structural helpers (`jjctx`, `jjstack`, `jjconflicts`, `jjcheckpoint`) query committed / op-log state where the flag is strictly correct. Task 2's shipped code, catalog, and tests reflect four; Task 3's allowlist is four values. Some Task 2 code blocks below still show the original six — the committed code is authoritative.

## Global Constraints

- **VCS is jj, never git.** Commit with `jj describe -m "…"` then `jj new`. The only exceptions are `jj git` subcommands and `gh`.
- **Four functions only** — `jjctx`, `jjstack`, `jjconflicts`, `jjcheckpoint` — plus the private `_jjq`. No mutation wrappers, no workspace helpers, no `jjhelp`, no working-copy helpers (`jjclean`/`jjfiles` cut — see Revision note).
- **Function bodies are bash+zsh compatible** (use `printf`, `[ … ]`, `local` — not zsh-only `print`/`typeset`), so the bash test harness can source them while they still install into `~/.zshrc`. Install target is zsh only (`~/.zshrc`); bash install is a non-goal.
- **The installer uses `$HOME` explicitly** (never literal `~`) for every target path, so tests can override `HOME`. Targets: `~/.config/jj-agent-helpers/jj-agent-helpers.sh`, `~/.zshrc`, `~/.claude/CLAUDE.md`, `~/.claude/settings.json`.
- **Every read-only function body must contain `--ignore-working-copy`** (via `_jjq`). This is the feature's reason to exist; a test enforces it.
- **All prose in this repo's own words.**
- **Marker fences** (exact strings, used verbatim by the installer and tests):
  - zshrc: `# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>` … `# <<< jj-agent-helpers <<<`
  - CLAUDE.md: `<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->` … `<!-- END jj-agent-helpers -->`
  - settings.json allowlist values (four): `Bash(jjctx:*)`, `Bash(jjstack:*)`, `Bash(jjconflicts:*)`, `Bash(jjcheckpoint:*)`

---

## File Structure

```
plugins/agent-helpers-jj/
  .claude-plugin/plugin.json                 # manifest
  README.md
  LICENSE
  scripts/
    jj-agent-helpers.sh                       # the six functions + _jjq (sourced into ~/.zshrc)
    agent-helpers-install.sh                  # install/remove mechanism (testable, non-interactive)
  templates/
    jj-agent-helpers-claudemd.md              # the fenced CLAUDE.md catalog block
  commands/
    agent-helpers-setup.md                    # consent + invoke installer + report + restart reminder
    agent-helpers-remove.md                   # invoke installer remove + report
  tests/
    test-jj-agent-helpers.sh                  # unit: the six functions in a scratch jj repo
    test-agent-helpers-install.sh             # installer: setup→setup→remove against a fake $HOME
```
Plus one modification: add the plugin to `./.claude-plugin/marketplace.json`.

---

### Task 1: Plugin scaffold + marketplace registration

**Files:**
- Create: `plugins/agent-helpers-jj/.claude-plugin/plugin.json`
- Create: `plugins/agent-helpers-jj/README.md`
- Create: `plugins/agent-helpers-jj/LICENSE`
- Modify: `.claude-plugin/marketplace.json` (append one plugin entry)

**Interfaces:**
- Consumes: nothing.
- Produces: a registered plugin `agent-helpers-jj` other tasks add files under.

- [ ] **Step 1: Create the plugin manifest**

Create `plugins/agent-helpers-jj/.claude-plugin/plugin.json` (no hooks — this plugin ships no hooks):

```json
{
  "name": "agent-helpers-jj",
  "description": "Machine-level jj (Jujutsu) query shortcuts for agents — read-only helpers that bake in --ignore-working-copy so concurrent workspaces don't race",
  "author": {
    "name": "muloka",
    "email": "muloka@users.noreply.github.com"
  }
}
```

- [ ] **Step 2: Add the LICENSE**

Copy the existing MIT license verbatim so the new plugin matches its siblings:

```bash
cp plugins/project-setup-jj/LICENSE plugins/agent-helpers-jj/LICENSE
```

- [ ] **Step 3: Create the README**

Create `plugins/agent-helpers-jj/README.md`:

```markdown
# agent-helpers-jj

Machine-level jj (Jujutsu) query shortcuts for agents. Six read-only shell
functions, each wrapping `jj --ignore-working-copy …`, so an agent orienting
inside a jj repo never writes a working-copy snapshot to the shared operation
log — the serialization point that concurrent workspaces (e.g. fan-flames)
would otherwise race on.

| Function | Output | Purpose |
|---|---|---|
| `jjctx` | one JSON object | current change (orientation) |
| `jjstack` | JSONL | local changes ahead of trunk |
| `jjfiles [rev]` | JSONL | changed files `{path,status}` in `<rev>` (default `@`) |
| `jjconflicts` | exit code | 0 = clean, 1 = conflicts (printed), >1 = jj error |
| `jjcheckpoint` | short op id | for a fan-flames ledger `start-op` |
| `jjclean` | exit code | 0 = working copy has no changes |

## Install

```
/agent-helpers-setup
```

This is a **machine-level, one-time** install (not per-project). It:
1. copies the helper script to `~/.config/jj-agent-helpers/jj-agent-helpers.sh`;
2. adds a `source` line to `~/.zshrc` (consent-gated);
3. adds a one-line catalog to `~/.claude/CLAUDE.md` so agents know the helpers exist;
4. allowlists the six helpers in `~/.claude/settings.json` so they run prompt-free.

**Restart Claude Code afterward** — the helpers become callable only once the next
session regenerates its shell snapshot.

Uninstall with `/agent-helpers-remove` (reverses all four steps).

Requires zsh and `jj`. Bash shells are not supported in this version.
```

- [ ] **Step 4: Register in the marketplace manifest**

In `.claude-plugin/marketplace.json`, append this object to the `plugins` array (after the `workspace-jj` entry):

```json
    {
      "name": "agent-helpers-jj",
      "description": "Machine-level jj (Jujutsu) query shortcuts for agents — read-only helpers that bake in --ignore-working-copy so concurrent workspaces don't race",
      "author": {
        "name": "muloka",
        "email": "muloka@users.noreply.github.com"
      },
      "source": "./plugins/agent-helpers-jj",
      "category": "productivity",
      "homepage": "https://github.com/muloka/claude-plugins/tree/main/plugins/agent-helpers-jj"
    }
```

- [ ] **Step 5: Verify the manifests parse and the entry is present**

Run:
```bash
jq . plugins/agent-helpers-jj/.claude-plugin/plugin.json >/dev/null && echo "plugin.json OK"
jq -e '.plugins[] | select(.name=="agent-helpers-jj")' .claude-plugin/marketplace.json >/dev/null && echo "marketplace entry OK"
```
Expected: both print `… OK` and exit 0.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(agent-helpers-jj): scaffold plugin + marketplace entry

New single-purpose plugin for machine-level jj query helpers. Manifest,
README, MIT license, and marketplace registration; no components yet."
jj new
```

---

### Task 2: Function library + catalog template + unit/drift tests

**Files:**
- Create: `plugins/agent-helpers-jj/scripts/jj-agent-helpers.sh`
- Create: `plugins/agent-helpers-jj/templates/jj-agent-helpers-claudemd.md`
- Create/Test: `plugins/agent-helpers-jj/tests/test-jj-agent-helpers.sh`

**Interfaces:**
- Consumes: Task 1's plugin directory.
- Produces: the six functions (`jjctx`, `jjstack`, `jjfiles`, `jjconflicts`, `jjcheckpoint`, `jjclean`) sourced from `scripts/jj-agent-helpers.sh`; the fenced catalog block in `templates/jj-agent-helpers-claudemd.md` (consumed by Task 3's installer).

- [ ] **Step 1: Write the failing unit test harness**

Create `plugins/agent-helpers-jj/tests/test-jj-agent-helpers.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Unit tests for the six jj query helper functions.
# Creates a scratch jj repo, sources the helpers, exercises each function,
# and enforces the --ignore-working-copy invariant + catalog drift guard.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$SCRIPT_DIR/../scripts/jj-agent-helpers.sh"
TEMPLATE="$SCRIPT_DIR/../templates/jj-agent-helpers-claudemd.md"

pass=0
fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

# --- scratch jj repo ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export JJ_CONFIG="$WORK/jjconfig.toml"
cat > "$JJ_CONFIG" <<'CFG'
[user]
name = "test"
email = "test@example.com"
CFG
cd "$WORK"
jj git init repo >/dev/null 2>&1
cd repo
# seed one described change so trunk()..@ is non-empty. trunk() falls back to
# the root commit when there is no origin remote — fine here, because we assert
# jjstack is NON-empty (a local `main` bookmark would not influence trunk();
# that needs a real main@origin remote, which is more setup than this test needs).
jj describe -m seed >/dev/null 2>&1
jj new >/dev/null 2>&1   # @ is now an empty change on top of the seed

# shellcheck disable=SC1090
. "$HELPERS"

# jjctx: one JSON object carrying a change_id
out="$(jjctx)"
if printf '%s' "$out" | jq -e '.change_id' >/dev/null 2>&1; then ok "jjctx emits JSON with change_id"; else bad "jjctx" "no change_id in: $out"; fi

# jjcheckpoint: non-empty short op id
out="$(jjcheckpoint)"
if [ -n "$out" ]; then ok "jjcheckpoint prints an op id"; else bad "jjcheckpoint" "empty"; fi

# jjclean: empty @ -> exit 0
if jjclean; then ok "jjclean exits 0 on empty @"; else bad "jjclean(empty)" "expected 0"; fi

# make @ dirty, then jjclean -> non-zero, jjfiles -> JSONL, jjstack -> includes this change
echo hello > a.txt
if jjclean; then bad "jjclean(dirty)" "expected non-zero"; else ok "jjclean non-zero on dirty @"; fi

out="$(jjfiles)"
if printf '%s' "$out" | head -1 | jq -e '.path and .status' >/dev/null 2>&1; then ok "jjfiles emits {path,status} JSONL"; else bad "jjfiles" "bad line: $out"; fi

out="$(jjstack)"
if [ -n "$out" ] && printf '%s' "$out" | head -1 | jq -e '.change_id' >/dev/null 2>&1; then ok "jjstack emits JSONL ahead of trunk"; else bad "jjstack" "bad: $out"; fi

# jjconflicts: clean repo -> exit 0
if jjconflicts; then ok "jjconflicts exits 0 when clean"; else bad "jjconflicts(clean)" "expected 0"; fi

# jjconflicts: broken env (not a jj repo) -> non-zero, NOT a false clean
( cd "$WORK" && jjconflicts >/dev/null 2>&1 ) && bad "jjconflicts(non-repo)" "returned clean outside a jj repo" || ok "jjconflicts non-zero outside a jj repo"

# --ignore-working-copy invariant: the ONLY direct `jj ` call is _jjq's (which
# carries the flag). Every helper otherwise routes through _jjq — so no line may
# invoke bare `jj ` without --ignore-working-copy. (Robust across multi-line bodies.)
bare="$(grep -nE '(^|[^_A-Za-z])jj ' "$HELPERS" | grep -v -- '--ignore-working-copy' || true)"
if grep -q -- '--ignore-working-copy' "$HELPERS" && [ -z "$bare" ]; then
  ok "all direct jj calls carry --ignore-working-copy"
else
  bad "invariant" "jj called without the flag: $bare"
fi

# drift guard: catalog names == public function names (exclude private _jjq)
defined="$(grep -Eo '^(jj[a-z]+)\(\)' "$HELPERS" | sed 's/()//' | sort -u)"
catalog="$(grep -Eo '`jj[a-z]+' "$TEMPLATE" | tr -d '`' | sort -u)"
if [ "$defined" = "$catalog" ]; then ok "catalog matches defined public functions"; else bad "drift" "defined=[$defined] catalog=[$catalog]"; fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash plugins/agent-helpers-jj/tests/test-jj-agent-helpers.sh`
Expected: FAIL — the harness can't source `scripts/jj-agent-helpers.sh` (doesn't exist yet), erroring at the `. "$HELPERS"` line.

- [ ] **Step 3: Write the function library**

Create `plugins/agent-helpers-jj/scripts/jj-agent-helpers.sh`:

```bash
# jj query helpers for agents. Sourced from ~/.zshrc by agent-helpers-jj.
# Bodies are bash+zsh compatible (printf / [ ] / local), so the bash test
# harness can source them while they install into zsh.
#
# _jjq is the single place the --ignore-working-copy flag lives: read-only
# queries must never snapshot the working copy (that writes a new operation to
# the shared op-log, the serialization point concurrent jj workspaces race on).

_jjq() { jj --ignore-working-copy "$@"; }

# jjctx — current change as one JSON object (orientation)
jjctx() { _jjq log -r @ --no-graph -T 'json(self) ++ "\n"'; }

# jjstack — local changes ahead of trunk, JSON lines
jjstack() { _jjq log -r 'trunk()..@' --no-graph -T 'json(self) ++ "\n"'; }

# jjfiles [rev] — changed files in <rev|@> as JSONL {path,status}
jjfiles() {
  _jjq diff -r "${1:-@}" -T '"{ \"path\": " ++ self.path().display().escape_json() ++ ", \"status\": " ++ self.status().escape_json() ++ " }\n"'
}

# jjclean — exit 0 if the working copy has no changes
jjclean() { [ "$(_jjq log -r @ --no-graph -T 'if(empty,"1","0")')" = 1 ]; }

# jjconflicts — 0 = clean, 1 = conflicts (printed), >1 = real jj error.
# On jj 0.43 `jj resolve --list` exits 0 (and lists) when conflicts exist, and
# exits 2 ("No conflicts found…") when clean. Distinguishing exit 2 from other
# errors stops an agent reading "clean" from a broken env (not a repo / jj gone).
jjconflicts() {
  local out rc
  out="$(_jjq resolve --list 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$out" ] && return 0
    printf '%s\n' "$out"; return 1
  fi
  [ "$rc" -eq 2 ] && return 0
  printf 'jjconflicts: jj error (rc=%s)\n' "$rc" >&2
  return "$rc"
}

# jjcheckpoint — current operation id (for a fan-flames ledger start-op)
jjcheckpoint() { _jjq op log -n1 --no-graph -T 'id.short()'; }
```

- [ ] **Step 4: Write the catalog template**

Create `plugins/agent-helpers-jj/templates/jj-agent-helpers-claudemd.md` (this exact fenced block is inserted into `~/.claude/CLAUDE.md` by the installer):

```markdown
<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->
**jj query helpers** (run in jj repos; all use `--ignore-working-copy`, safe under concurrent workspaces): `jjctx` current change (one JSON object) · `jjstack` local changes vs trunk (JSONL) · `jjfiles [rev]` changed files (JSONL) · `jjconflicts` (exit 0 = clean) · `jjcheckpoint` op id · `jjclean` (exit 0 = nothing to commit)
<!-- END jj-agent-helpers -->
```

- [ ] **Step 5: Run the unit tests to confirm they pass**

Run: `bash plugins/agent-helpers-jj/tests/test-jj-agent-helpers.sh`
Expected: every line `PASS`, final line `N passed, 0 failed`, exit 0.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat(agent-helpers-jj): six read-only jj query helpers + tests

jjctx/jjstack/jjfiles/jjconflicts/jjcheckpoint/jjclean, each routed through
_jjq (--ignore-working-copy) so read-only orientation never snapshots the
working copy. Bash+zsh compatible bodies; unit tests assert JSON/exit-code
contracts, the --ignore-working-copy invariant, and catalog drift."
jj new
```

---

### Task 3: Installer script + installer tests (the risk surface)

**Files:**
- Create: `plugins/agent-helpers-jj/scripts/agent-helpers-install.sh`
- Create/Test: `plugins/agent-helpers-jj/tests/test-agent-helpers-install.sh`

**Interfaces:**
- Consumes: `scripts/jj-agent-helpers.sh` (its sibling) and `templates/jj-agent-helpers-claudemd.md` (from Task 2).
- Produces: `agent-helpers-install.sh install` / `remove` — the non-interactive mechanism Task 4's commands invoke. Reads all targets from `$HOME` so tests can override it.

- [ ] **Step 1: Write the failing installer test**

Create `plugins/agent-helpers-jj/tests/test-agent-helpers-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Installer idempotency + reversibility against a FAKE $HOME.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/../scripts/agent-helpers-install.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT

# seed a realistic home
mkdir -p "$FAKE/.claude"
printf '# my zshrc\nexport FOO=1\n' > "$FAKE/.zshrc"
printf '# My global instructions\n\nPrefer jj over git.\n' > "$FAKE/.claude/CLAUDE.md"
printf '{\n  "permissions": {\n    "allow": ["Bash(ls:*)"]\n  }\n}\n' > "$FAKE/.claude/settings.json"

ZSHRC_ORIG="$(cat "$FAKE/.zshrc")"
CLAUDE_ORIG="$(cat "$FAKE/.claude/CLAUDE.md")"
SETTINGS_ORIG_SEMANTIC="$(jq -S . "$FAKE/.claude/settings.json")"

run() { HOME="$FAKE" bash "$INSTALL" "$1"; }

# --- install ---
run install
grep -qxF '# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>' "$FAKE/.zshrc" && ok "zshrc fence present" || bad "install/zshrc" "no fence"
grep -qF 'source' "$FAKE/.zshrc" && grep -qF '.config/jj-agent-helpers/jj-agent-helpers.sh' "$FAKE/.zshrc" && ok "zshrc source line present" || bad "install/zshrc" "no source line"
[ -f "$FAKE/.config/jj-agent-helpers/jj-agent-helpers.sh" ] && ok "helper script copied" || bad "install/copy" "missing"
grep -qxF '<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->' "$FAKE/.claude/CLAUDE.md" && ok "CLAUDE.md fence present" || bad "install/claude" "no fence"
[ "$(jq -r '.permissions.allow | index("Bash(jjctx:*)") != null' "$FAKE/.claude/settings.json")" = true ] && ok "settings allowlist added" || bad "install/settings" "jjctx missing"
[ "$(jq -r '.permissions.allow | index("Bash(ls:*)") != null' "$FAKE/.claude/settings.json")" = true ] && ok "settings preserved existing entry" || bad "install/settings" "clobbered ls"

# --- idempotent second install ---
run install
zcount=$(grep -cxF '# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>' "$FAKE/.zshrc")
[ "$zcount" -eq 1 ] && ok "idempotent: one zshrc fence" || bad "idempotent/zshrc" "count=$zcount"
ccount=$(grep -cxF '<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->' "$FAKE/.claude/CLAUDE.md")
[ "$ccount" -eq 1 ] && ok "idempotent: one CLAUDE.md fence" || bad "idempotent/claude" "count=$ccount"
jcount=$(jq '[.permissions.allow[] | select(. == "Bash(jjctx:*)")] | length' "$FAKE/.claude/settings.json")
[ "$jcount" -eq 1 ] && ok "idempotent: no duplicate allowlist value" || bad "idempotent/settings" "count=$jcount"

# --- remove restores originals ---
run remove
[ "$(cat "$FAKE/.zshrc")" = "$ZSHRC_ORIG" ] && ok "remove restores ~/.zshrc byte-identical" || bad "remove/zshrc" "differs: $(cat "$FAKE/.zshrc")"
[ "$(cat "$FAKE/.claude/CLAUDE.md")" = "$CLAUDE_ORIG" ] && ok "remove restores CLAUDE.md byte-identical" || bad "remove/claude" "differs"
[ "$(jq -S . "$FAKE/.claude/settings.json")" = "$SETTINGS_ORIG_SEMANTIC" ] && ok "remove restores settings.json semantically" || bad "remove/settings" "differs: $(jq -S . "$FAKE/.claude/settings.json")"
[ ! -f "$FAKE/.config/jj-agent-helpers/jj-agent-helpers.sh" ] && ok "remove deletes helper script" || bad "remove/copy" "still present"

# --- missing-file paths ---
FAKE2="$(mktemp -d)"; trap 'rm -rf "$FAKE" "$FAKE2"' EXIT
HOME="$FAKE2" bash "$INSTALL" install
grep -qxF '# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>' "$FAKE2/.zshrc" && ok "install creates missing ~/.zshrc" || bad "missing/zshrc" "not created"
[ "$(jq -r '.permissions.allow | index("Bash(jjctx:*)") != null' "$FAKE2/.claude/settings.json")" = true ] && ok "install creates missing settings.json with allow" || bad "missing/settings" "not created"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bash plugins/agent-helpers-jj/tests/test-agent-helpers-install.sh`
Expected: FAIL — `agent-helpers-install.sh` doesn't exist, so `run install` errors immediately.

- [ ] **Step 3: Write the installer script**

Create `plugins/agent-helpers-jj/scripts/agent-helpers-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Non-interactive install/remove mechanism for agent-helpers-jj.
# Consent + reporting live in the command markdown; this script is the tested
# mechanism. All targets come from $HOME so tests can override it.
#
# Usage: agent-helpers-install.sh {install|remove}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/jj-agent-helpers.sh"
TEMPLATE="$SCRIPT_DIR/../templates/jj-agent-helpers-claudemd.md"

HELPER_DIR="$HOME/.config/jj-agent-helpers"
HELPER_PATH="$HELPER_DIR/jj-agent-helpers.sh"
ZSHRC="$HOME/.zshrc"
CLAUDEMD="$HOME/.claude/CLAUDE.md"
SETTINGS="$HOME/.claude/settings.json"

Z_BEGIN="# >>> jj-agent-helpers (managed by agent-helpers-jj) >>>"
Z_END="# <<< jj-agent-helpers <<<"
C_BEGIN="<!-- BEGIN jj-agent-helpers (agent-helpers-jj) -->"
C_END="<!-- END jj-agent-helpers -->"
ALLOW=("Bash(jjctx:*)" "Bash(jjstack:*)" "Bash(jjconflicts:*)" "Bash(jjcheckpoint:*)")

# strip_fence FILE BEGIN END — remove the fenced block and one preceding blank line
strip_fence() {
  local file="$1" begin="$2" end="$3" bl el start
  [ -f "$file" ] || return 0
  grep -qxF "$begin" "$file" || return 0
  bl=$(grep -nxF "$begin" "$file" | head -1 | cut -d: -f1)
  el=$(grep -nxF "$end"   "$file" | head -1 | cut -d: -f1)
  { [ -n "$bl" ] && [ -n "$el" ] && [ "$el" -ge "$bl" ]; } || return 0
  start="$bl"
  if [ "$bl" -gt 1 ] && [ -z "$(sed -n "$((bl-1))p" "$file")" ]; then start=$((bl-1)); fi
  sed "${start},${el}d" "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# append_block FILE BLOCK — ensure trailing newline + one blank separator, then append BLOCK
append_block() {
  local file="$1" block="$2"
  if [ -s "$file" ]; then
    [ "$(tail -c1 "$file" | wc -l)" -eq 1 ] || printf '\n' >> "$file"
    printf '\n' >> "$file"
  else
    : > "$file"
  fi
  printf '%s\n' "$block" >> "$file"
}

settings_json_array() { printf '%s\n' "${ALLOW[@]}" | jq -R . | jq -s .; }

settings_add() {
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
  jq --argjson add "$(settings_json_array)" '
    .permissions = (.permissions // {})
    | .permissions.allow = ((.permissions.allow // []) as $cur
        | $cur + [ $add[] | select(. as $x | ($cur | index($x)) | not) ])
  ' "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
}

settings_remove() {
  [ -f "$SETTINGS" ] || return 0
  jq --argjson rm "$(settings_json_array)" '
    (if (.permissions.allow // null) != null then .permissions.allow -= $rm else . end)
    | (if (.permissions.allow == []) then del(.permissions.allow) else . end)
    | (if (.permissions == {}) then del(.permissions) else . end)
  ' "$SETTINGS" > "$SETTINGS.tmp"
  mv "$SETTINGS.tmp" "$SETTINGS"
}

cmd_install() {
  mkdir -p "$HELPER_DIR"
  cp "$SRC" "$HELPER_PATH"
  strip_fence "$ZSHRC" "$Z_BEGIN" "$Z_END"
  append_block "$ZSHRC" "$(printf '%s\nsource %s\n%s' "$Z_BEGIN" "$HELPER_PATH" "$Z_END")"
  mkdir -p "$(dirname "$CLAUDEMD")"
  strip_fence "$CLAUDEMD" "$C_BEGIN" "$C_END"
  append_block "$CLAUDEMD" "$(cat "$TEMPLATE")"
  settings_add
}

cmd_remove() {
  strip_fence "$ZSHRC" "$Z_BEGIN" "$Z_END"
  strip_fence "$CLAUDEMD" "$C_BEGIN" "$C_END"
  settings_remove
  rm -f "$HELPER_PATH"
  rmdir "$HELPER_DIR" 2>/dev/null || true
}

case "${1:-}" in
  install) cmd_install ;;
  remove)  cmd_remove ;;
  *) echo "usage: $0 {install|remove}" >&2; exit 2 ;;
esac
```

- [ ] **Step 4: Run the installer tests to confirm they pass**

Run: `bash plugins/agent-helpers-jj/tests/test-agent-helpers-install.sh`
Expected: every line `PASS`, final line `N passed, 0 failed`, exit 0. If the byte-identical `remove` assertions fail, inspect the reported diff — the usual cause is `append_block`'s blank-line handling vs `strip_fence`'s preceding-blank removal not cancelling; they must be exact inverses.

- [ ] **Step 5: Make the scripts executable and commit**

```bash
chmod +x plugins/agent-helpers-jj/scripts/agent-helpers-install.sh
jj describe -m "feat(agent-helpers-jj): idempotent, reversible installer + tests

agent-helpers-install.sh install/remove edits ~/.zshrc, ~/.claude/CLAUDE.md,
and ~/.claude/settings.json behind marker fences (known-value jq dedupe for
JSON), reading all paths from \$HOME. Tests assert idempotent re-run, byte
round-trip for the two text files, semantic round-trip for JSON, and
missing-file creation — against a fake \$HOME."
jj new
```

---

### Task 4: Setup + remove commands (thin wrappers) + restart UX

**Files:**
- Create: `plugins/agent-helpers-jj/commands/agent-helpers-setup.md`
- Create: `plugins/agent-helpers-jj/commands/agent-helpers-remove.md`

**Interfaces:**
- Consumes: `scripts/agent-helpers-install.sh` (Task 3) via `${CLAUDE_PLUGIN_ROOT}`.
- Produces: user-facing `/agent-helpers-setup` and `/agent-helpers-remove` commands.

- [ ] **Step 1: Create the setup command**

Create `plugins/agent-helpers-jj/commands/agent-helpers-setup.md`:

```markdown
---
description: Install machine-level jj query helpers (jjctx, jjstack, …) for agents
allowed-tools: Bash(jj:*), Bash(bash:*), Bash(cat:*), Bash(grep:*), Read
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Install the read-only jj query helpers **machine-wide** (not per-project). This writes to three files under the user's home directory, so you MUST get consent first.

### Step 1: Explain and get consent

Tell the user this will:
- copy the helper script to `~/.config/jj-agent-helpers/jj-agent-helpers.sh`
- add a `source` line to `~/.zshrc` (fenced, removable)
- add a one-line catalog block to `~/.claude/CLAUDE.md`
- add six `Bash(jj…:*)` entries to `permissions.allow` in `~/.claude/settings.json`

Ask for explicit confirmation before proceeding. If the user declines, print the four changes they could make by hand (the `source` line and the fence markers are in `${CLAUDE_PLUGIN_ROOT}/scripts/agent-helpers-install.sh`) and stop without changing anything.

### Step 2: Run the installer

On confirmation:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-helpers-install.sh" install
```
The script is idempotent — re-running it will not create duplicates.

### Step 3: Report and remind

Report what changed (the four targets above). Then, prominently:

> **Restart Claude Code (or start a new session) for the helpers to take effect.** They become callable only after the next session regenerates its shell snapshot; the permission allowlist also applies from the next session.

Warn if any of the names `jjctx`, `jjstack`, `jjfiles`, `jjconflicts`, `jjcheckpoint`, `jjclean`, or `_jjq` were already defined in the user's shell (the source line will shadow them). Remove with `/agent-helpers-remove`.
```

- [ ] **Step 2: Create the remove command**

Create `plugins/agent-helpers-jj/commands/agent-helpers-remove.md`:

```markdown
---
description: Remove the machine-level jj query helpers installed by agent-helpers-jj
allowed-tools: Bash(jj:*), Bash(bash:*), Read
---

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — not even for context discovery. Always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Your Task

Reverse the machine-level install performed by `/agent-helpers-setup`.

### Step 1: Run the uninstaller

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/agent-helpers-install.sh" remove
```
This is idempotent and safe to run even if nothing is installed. It removes the fenced blocks from `~/.zshrc` and `~/.claude/CLAUDE.md`, filters the six values out of `~/.claude/settings.json`, and deletes `~/.config/jj-agent-helpers/jj-agent-helpers.sh`.

### Step 2: Report and remind

Report the four reversals. Then remind:

> **Restart Claude Code (or start a new session)** so the removed functions and allowlist entries stop applying.
```

- [ ] **Step 3: Verify frontmatter and plugin-root references**

Run:
```bash
head -4 plugins/agent-helpers-jj/commands/agent-helpers-setup.md
grep -c 'CLAUDE_PLUGIN_ROOT' plugins/agent-helpers-jj/commands/agent-helpers-setup.md plugins/agent-helpers-jj/commands/agent-helpers-remove.md
```
Expected: setup frontmatter shows `description:` + `allowed-tools:`; each command references `${CLAUDE_PLUGIN_ROOT}` at least once.

- [ ] **Step 4: Commit**

```bash
jj describe -m "feat(agent-helpers-jj): /agent-helpers-setup and /agent-helpers-remove

Thin command wrappers over agent-helpers-install.sh: setup gates the
machine-level write behind explicit consent, invokes the installer, reports
the four targets, and prominently reminds the user to restart so the shell
snapshot regenerates. Remove reverses it."
jj new
```

---

## Verification (whole plan)

1. `bash plugins/agent-helpers-jj/tests/test-jj-agent-helpers.sh` — all PASS, `0 failed`.
2. `bash plugins/agent-helpers-jj/tests/test-agent-helpers-install.sh` — all PASS, `0 failed` (idempotency + byte/semantic round-trips + missing-file creation).
3. `jq -e '.plugins[] | select(.name=="agent-helpers-jj")' .claude-plugin/marketplace.json` — exits 0.
4. `grep -rl -- '--ignore-working-copy' plugins/agent-helpers-jj/scripts/jj-agent-helpers.sh` — hits (the invariant is present in source).
5. Manual smoke (optional, real `$HOME`): run `/agent-helpers-setup`, confirm the three fenced/known-value markers appear, restart, then confirm an agent can call `jjctx` prompt-free; run `/agent-helpers-remove` and confirm the markers are gone.
6. Read the two command files once for coherence — consent gate present in setup, restart reminder present in both.
