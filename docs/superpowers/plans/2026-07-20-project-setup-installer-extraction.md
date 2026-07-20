# `/project-setup` Installer Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `/project-setup`'s deterministic install logic into a testable `project-setup-install.sh`, add a bash test that pins its idempotency/no-clobber contract, and shrink the command to a thin wrapper (#78).

**Architecture:** A new no-jj installer script does the copies + `settings.local.json` deep-merge (replace-by-identity at hook granularity) + CLAUDE.md 4-case hash logic, emitting a `key=value` summary. A bash test drives it (TDD) against fabricated temp plugin/project roots — no jj needed. The command reduces to: jj-root gate → call installer via `${CLAUDE_PLUGIN_ROOT}` → relay the summary.

**Tech Stack:** bash 3.2, `jq`, `md5`/`md5sum`. Tests are plain bash suites run by `.github/workflows/test.yml`.

**Spec:** `docs/superpowers/specs/2026-07-20-project-setup-installer-extraction-design.md`

## Global Constraints

- **VCS is jj.** Working copy IS a commit. "Commit" steps use `jj describe -m` then `jj new`. Never raw `git`. Use `gh` for GitHub.
- **bash 3.2 (hard).** macOS `/bin/bash` 3.2.57 in the suite + ubuntu bash 5 in CI. No globstar, no associative arrays, no `mapfile`. Test with `/bin/bash <script>`, not zsh.
- **The installer script has NO jj dependency** — it takes `<plugin-root> <project-root>` as explicit args and does pure file ops.
- **CI fails red on an unbumped plugin (#84):** any changed byte under `plugins/project-setup-jj/` requires bumping its `version`. This PR bumps `project-setup-jj` 0.1.2 → 0.1.3.
- **Test discovery glob:** `find plugins .github -path '*/tests/test-*.sh'`. The new suite at `plugins/project-setup-jj/tests/test-project-setup-install.sh` is auto-found.
- **Merge contract (the thing under test):** managed hooks replaced by identity at **hook granularity** (strip our hook from every entry's `.hooks[]`, drop emptied entries, append ours) so a user hook co-located in the same entry survives; PreCompact by value-equality; permissions union-deduped; **malformed existing `settings.local.json` → abort non-zero, never overwrite.**
- **CLAUDE.md template markers:** `<!-- jj-project-setup:start hash:<8hex> -->` … `<!-- jj-project-setup:end -->`. Body hash = md5 of content strictly between the markers, first 8 hex. The **real** template's hash is already covered by `test-template-hash.sh`; the new test uses a fabricated template and only exercises install *logic*.

---

## Task 1: The installer script + its test (TDD)

**Files:**
- Create: `plugins/project-setup-jj/tests/test-project-setup-install.sh`
- Create: `plugins/project-setup-jj/scripts/project-setup-install.sh`

**Interfaces:**
- Produces: `project-setup-install.sh <plugin-root> <project-root>` — copies the four consumer hook scripts, merges `settings.local.json`, installs/updates CLAUDE.md, prints `key=value` summary (`session_start=copied`, `require_jj_new=copied`, `workspace_hooks=copied`, `settings=created|merged`, `claude_md=created|updated|unchanged`, `restart_required=true`). Exit non-zero (touching nothing) if `<project-root>/.claude/settings.local.json` exists but is invalid JSON.

- [ ] **Step 1: Write the failing test suite**

Create `plugins/project-setup-jj/tests/test-project-setup-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Installer contract for project-setup-install.sh (#78): copies, settings
# deep-merge (replace-by-identity at hook granularity), CLAUDE.md 4-case,
# malformed-JSON no-clobber. No jj needed — explicit plugin/project roots.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/../scripts/project-setup-install.sh"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

# Fabricate a fake plugin root (scripts/ + templates/) once.
PLUG="$(mktemp -d)"
trap 'rm -rf "$PLUG"' EXIT
mkdir -p "$PLUG/scripts" "$PLUG/templates"
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  printf '#!/usr/bin/env bash\n# stub %s\n' "$s" > "$PLUG/scripts/$s"
done
cat > "$PLUG/templates/CLAUDE.md.template" <<'TPL'
<!-- jj-project-setup:start hash:PLACEHOLDER -->
## VCS — jj (Jujutsu)

Use jj, not git.
<!-- jj-project-setup:end -->
TPL
# Compute the real body hash and stamp it into the fabricated template's marker,
# exactly as a maintainer would, so case-2 "unchanged" is reachable.
md5hash() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum; fi | cut -c1-8; }
BODYHASH=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$PLUG/templates/CLAUDE.md.template" | sed '1d;$d' | md5hash)
sed "s/hash:PLACEHOLDER/hash:$BODYHASH/" "$PLUG/templates/CLAUDE.md.template" > "$PLUG/templates/CLAUDE.md.template.tmp"
mv "$PLUG/templates/CLAUDE.md.template.tmp" "$PLUG/templates/CLAUDE.md.template"

newproj() { mktemp -d; }   # fresh project root per case

# ---- Case 1: fresh install ----
P=$(newproj)
OUT=$(bash "$INSTALL" "$PLUG" "$P")
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  [ -x "$P/.claude/scripts/$s" ] && ok "fresh: $s copied +x" || bad "fresh" "$s not executable/copied"
done
jq empty "$P/.claude/settings.local.json" 2>/dev/null && ok "fresh: settings valid JSON" || bad "fresh" "settings not valid JSON"
for ev in SessionStart PreCompact PreToolUse WorktreeCreate WorktreeRemove; do
  [ "$(jq --arg e "$ev" '(.hooks[$e]|length) > 0' "$P/.claude/settings.local.json")" = true ] \
    && ok "fresh: hooks.$ev present" || bad "fresh" "hooks.$ev missing"
done
[ "$(jq '.permissions.allow | index("Bash(gh *)") != null' "$P/.claude/settings.local.json")" = true ] && ok "fresh: allow has gh" || bad "fresh" "allow missing gh"
[ "$(jq '.permissions.deny | index("Bash(git *)") != null' "$P/.claude/settings.local.json")" = true ] && ok "fresh: deny has git" || bad "fresh" "deny missing git"
[ -f "$P/CLAUDE.md" ] && grep -q 'jj-project-setup:start' "$P/CLAUDE.md" && ok "fresh: CLAUDE.md created w/ marker" || bad "fresh" "CLAUDE.md missing marker"
printf '%s\n' "$OUT" | grep -qx 'settings=created' && ok "fresh: summary settings=created" || bad "fresh" "summary not created: $OUT"
printf '%s\n' "$OUT" | grep -qx 'claude_md=created' && ok "fresh: summary claude_md=created" || bad "fresh" "summary claude_md: $OUT"

# ---- Case 2: idempotent re-run (byte-identical) ----
BEFORE=$(cat "$P/.claude/settings.local.json")
OUT2=$(bash "$INSTALL" "$PLUG" "$P")
[ "$(cat "$P/.claude/settings.local.json")" = "$BEFORE" ] && ok "rerun: settings byte-identical" || bad "rerun" "settings changed on 2nd run"
printf '%s\n' "$OUT2" | grep -qx 'claude_md=unchanged' && ok "rerun: claude_md=unchanged" || bad "rerun" "claude_md not unchanged: $OUT2"

# ---- Case 3: unrelated hook + permission preserved ----
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"x","hooks":[{"type":"command","command":"/opt/mine/other.sh"}]}]},"permissions":{"allow":["Bash(mytool:*)"]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | index("/opt/mine/other.sh") != null' "$P/.claude/settings.local.json")" = true ] && ok "preserve: unrelated hook survives" || bad "preserve" "unrelated hook dropped"
[ "$(jq '.permissions.allow | index("Bash(mytool:*)") != null' "$P/.claude/settings.local.json")" = true ] && ok "preserve: unrelated permission survives" || bad "preserve" "unrelated permission dropped"
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("/.claude/scripts/jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "preserve: our SessionStart added exactly once" || bad "preserve" "our hook count != 1"

# ---- Case 4: stale-version managed hook replaced, not duplicated ----
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"OLD","hooks":[{"type":"command","command":"$P/.claude/scripts/jj-session-start.sh"}]}]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("/.claude/scripts/jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "stale: exactly one of our SessionStart" || bad "stale" "duplicate/zero after upgrade"
[ "$(jq '[.hooks.SessionStart[] | select(.matcher=="OLD")] | length' "$P/.claude/settings.local.json")" = 0 ] && ok "stale: OLD matcher gone" || bad "stale" "OLD entry survived"

# ---- Case 5: CLAUDE.md variants ----
# 5a matching hash -> unchanged, body untouched
P=$(newproj)
bash "$INSTALL" "$PLUG" "$P" >/dev/null           # creates CLAUDE.md w/ current hash
CM_BEFORE=$(cat "$P/CLAUDE.md")
OUT=$(bash "$INSTALL" "$PLUG" "$P")
[ "$(cat "$P/CLAUDE.md")" = "$CM_BEFORE" ] && printf '%s\n' "$OUT" | grep -qx 'claude_md=unchanged' && ok "claude_md 5a: matching hash unchanged" || bad "claude_md 5a" "changed or wrong summary"
# 5b no marker -> prepend, preserve existing
P=$(newproj); printf '# Existing\n\nkeep me\n' > "$P/CLAUDE.md"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
grep -q 'jj-project-setup:start' "$P/CLAUDE.md" && grep -q 'keep me' "$P/CLAUDE.md" && ok "claude_md 5b: prepended, existing kept" || bad "claude_md 5b" "marker or existing content missing"
# 5c differing hash -> section replaced, surrounding intact
P=$(newproj); mkdir -p "$P"
printf '# Top\n<!-- jj-project-setup:start hash:deadbeef -->\nOLD BODY\n<!-- jj-project-setup:end -->\n# Bottom\n' > "$P/CLAUDE.md"
bash "$INSTALL" "$PLUG" "$P" >/dev/null
grep -q 'Use jj, not git.' "$P/CLAUDE.md" && ! grep -q 'OLD BODY' "$P/CLAUDE.md" && grep -q '# Top' "$P/CLAUDE.md" && grep -q '# Bottom' "$P/CLAUDE.md" && ok "claude_md 5c: section replaced, surroundings intact" || bad "claude_md 5c" "replace wrong"

# ---- Case 6: malformed existing settings -> abort, no clobber ----
P=$(newproj); mkdir -p "$P/.claude"
printf '{not json' > "$P/.claude/settings.local.json"
RAW_BEFORE=$(cat "$P/.claude/settings.local.json")
if bash "$INSTALL" "$PLUG" "$P" >/dev/null 2>&1; then bad "malformed" "exited 0 on invalid JSON"; else ok "malformed: non-zero exit"; fi
[ "$(cat "$P/.claude/settings.local.json")" = "$RAW_BEFORE" ] && ok "malformed: file untouched" || bad "malformed" "file was clobbered"
[ ! -d "$P/.claude/scripts" ] && ok "malformed: no side effects (scripts/ not created)" || bad "malformed" ".claude/scripts created before abort"

# ---- Case 7: user hook co-located in same entry survives (hook granularity) ----
P=$(newproj); mkdir -p "$P/.claude"
cat > "$P/.claude/settings.local.json" <<JSON
{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"/opt/mine/user.sh"},{"type":"command","command":"$P/.claude/scripts/jj-session-start.sh"}]}]}}
JSON
bash "$INSTALL" "$PLUG" "$P" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | index("/opt/mine/user.sh") != null' "$P/.claude/settings.local.json")" = true ] && ok "colocated: user hook survives" || bad "colocated" "user hook dropped (entry-granularity bug)"
[ "$(jq '[.hooks.SessionStart[].hooks[].command] | map(select(endswith("/.claude/scripts/jj-session-start.sh"))) | length' "$P/.claude/settings.local.json")" = 1 ] && ok "colocated: our hook present once" || bad "colocated" "our hook count != 1"

echo ""
echo "=== Results: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the test to confirm it fails (red)**

Run: `bash plugins/project-setup-jj/tests/test-project-setup-install.sh`
Expected: FAIL — `project-setup-install.sh` does not exist yet, so every case errors/fails.

- [ ] **Step 3: Write the installer script**

Create `plugins/project-setup-jj/scripts/project-setup-install.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# project-setup-install.sh <plugin-root> <project-root>
# Deterministic installer for /project-setup (#78). No jj dependency.
# Copies the four consumer hook scripts, deep-merges hooks+permissions into
# <project-root>/.claude/settings.local.json (replace-by-identity at HOOK
# granularity; PreCompact by value; permissions union-deduped), installs/updates
# the CLAUDE.md section (4-case hash logic), and prints a key=value summary.
# Aborts without writing settings if an existing settings.local.json is invalid
# JSON. bash 3.2-safe.

PLUGIN_ROOT="${1:?usage: project-setup-install.sh <plugin-root> <project-root>}"
PROJECT_ROOT="${2:?usage: project-setup-install.sh <plugin-root> <project-root>}"

SRC="$PLUGIN_ROOT/scripts"
TEMPLATE="$PLUGIN_ROOT/templates/CLAUDE.md.template"
CLAUDE_DIR="$PROJECT_ROOT/.claude"
DST="$CLAUDE_DIR/scripts"
SETTINGS="$CLAUDE_DIR/settings.local.json"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"

# --- 0. fail-safe: validate an existing settings file BEFORE any side effect ---
# (must run before the copy loop so a malformed settings file aborts touching
# nothing on disk — not just leaving settings.local.json itself unchanged.)
if [ -f "$SETTINGS" ]; then
  if ! jq empty "$SETTINGS" >/dev/null 2>&1; then
    echo "ERROR: $SETTINGS exists but is not valid JSON; refusing to overwrite." >&2
    exit 1
  fi
  base=$(cat "$SETTINGS")
  settings_outcome="merged"
else
  base='{}'
  settings_outcome="created"
fi

# --- 1. dirs + copy the four consumer hook scripts ---
mkdir -p "$DST"
for s in jj-session-start.sh require-jj-new.sh jj-workspace-create.sh jj-workspace-remove.sh; do
  cp "$SRC/$s" "$DST/$s"
  chmod +x "$DST/$s"
done
echo "session_start=copied"
echo "require_jj_new=copied"
echo "workspace_hooks=copied"

# --- 2. settings.local.json merge ---
SS="$DST/jj-session-start.sh"
RJN="$DST/require-jj-new.sh"
WSC="$DST/jj-workspace-create.sh"
WSR="$DST/jj-workspace-remove.sh"

merged=$(printf '%s' "$base" | jq \
  --arg ss "$SS" --arg rjn "$RJN" --arg wsc "$WSC" --arg wsr "$WSR" '
  # hook-granularity replace-by-identity: strip hooks whose command ends with
  # $sfx from every entry of event $ev, drop emptied entries, append $new.
  def upsert($ev; $sfx; $new):
    .hooks[$ev] = (
      ((.hooks[$ev] // [])
        | map(.hooks = ((.hooks // []) | map(select((.command // "") | endswith($sfx) | not))))
        | map(select((.hooks // []) | length > 0)))
      + [$new]
    );
  def upsert_value($ev; $new):
    .hooks[$ev] = (((.hooks[$ev] // []) | map(select(. != $new))) + [$new]);

  ( .hooks //= {} )
  | upsert("SessionStart"; "/.claude/scripts/jj-session-start.sh";
      {matcher:"startup|resume|clear|compact", hooks:[{type:"command", command:$ss, async:false}]})
  | upsert("PreToolUse"; "/.claude/scripts/require-jj-new.sh";
      {matcher:"Edit|Write|NotebookEdit", hooks:[{type:"command", command:$rjn}]})
  | upsert("WorktreeCreate"; "/.claude/scripts/jj-workspace-create.sh";
      {hooks:[{type:"command", command:$wsc}]})
  | upsert("WorktreeRemove"; "/.claude/scripts/jj-workspace-remove.sh";
      {hooks:[{type:"command", command:$wsr}]})
  | upsert_value("PreCompact";
      {hooks:[{type:"command", command:"jj status >/dev/null 2>&1 || true"}]})
  | ( .permissions //= {} )
  | .permissions.allow = (((.permissions.allow // []) + [
      "Bash(jj status*)","Bash(jj diff*)","Bash(jj log*)","Bash(jj new*)",
      "Bash(jj commit*)","Bash(jj describe*)","Bash(jj bookmark*)","Bash(jj git push*)",
      "Bash(jj git fetch*)","Bash(jj rebase*)","Bash(jj squash*)","Bash(jj edit*)",
      "Bash(jj abandon*)","Bash(jj undo*)","Bash(jj op log*)","Bash(jj resolve*)",
      "Bash(jj root*)","Bash(jj file*)","Bash(jj split*)","Bash(jj config*)",
      "Bash(jj git remote*)","Bash(gh *)"
    ]) | unique)
  | .permissions.deny = (((.permissions.deny // []) + ["Bash(git *)"]) | unique)
  ')

mkdir -p "$CLAUDE_DIR"
printf '%s\n' "$merged" > "$SETTINGS"
echo "settings=$settings_outcome"

# --- 3. CLAUDE.md (4-case hash logic) ---
md5hash() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum; fi | cut -c1-8; }
tmpl_hash=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$TEMPLATE" | sed '1d;$d' | md5hash)

claude_outcome=""
if [ ! -f "$CLAUDE_MD" ]; then
  cp "$TEMPLATE" "$CLAUDE_MD"
  claude_outcome="created"
elif grep -q 'jj-project-setup:start' "$CLAUDE_MD"; then
  installed_hash=$(grep -o 'jj-project-setup:start hash:[0-9a-f]*' "$CLAUDE_MD" | head -1 | sed 's/.*hash://')
  if [ -n "$installed_hash" ] && [ "$installed_hash" = "$tmpl_hash" ]; then
    claude_outcome="unchanged"
  else
    s_line=$(grep -n 'jj-project-setup:start' "$CLAUDE_MD" | head -1 | cut -d: -f1)
    e_line=$(grep -n 'jj-project-setup:end' "$CLAUDE_MD" | head -1 | cut -d: -f1)
    { sed -n "1,$((s_line-1))p" "$CLAUDE_MD"; cat "$TEMPLATE"; sed -n "$((e_line+1)),\$p" "$CLAUDE_MD"; } > "$CLAUDE_MD.tmp"
    mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
    claude_outcome="updated"
  fi
else
  { cat "$TEMPLATE"; echo; cat "$CLAUDE_MD"; } > "$CLAUDE_MD.tmp"
  mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
  claude_outcome="updated"
fi
echo "claude_md=$claude_outcome"

echo "restart_required=true"
```

- [ ] **Step 4: Run the test to confirm it passes (green)**

Run: `bash plugins/project-setup-jj/tests/test-project-setup-install.sh`
Expected: PASS (`0 failed`). If any case fails, fix the script (not the test) and re-run — the test encodes the spec's contract.

- [ ] **Step 5: Commit (jj)**

```bash
jj describe -m "feat(#78): deterministic project-setup-install.sh + contract test

No-jj installer doing the copies, settings.local.json deep-merge
(replace-by-identity at hook granularity, PreCompact by value, permissions
union-deduped, malformed-JSON no-clobber), and the CLAUDE.md 4-case hash logic,
with a key=value summary. Test pins idempotency, unrelated-config survival,
stale-hook replacement, co-located-user-hook survival, and no-clobber."
jj new
```

---

## Task 2: Shrink the command + version bump

**Files:**
- Modify: `plugins/project-setup-jj/commands/project-setup.md` (replace Steps 2–6 with a call to the installer)
- Modify: `plugins/project-setup-jj/.claude-plugin/plugin.json` (0.1.2 → 0.1.3)

**Interfaces:**
- Consumes: `project-setup-install.sh` from Task 1 (via `${CLAUDE_PLUGIN_ROOT}`), and its `key=value` summary.

- [ ] **Step 1: Rewrite the command (frontmatter + body)**

Replace the **entire** `plugins/project-setup-jj/commands/project-setup.md`, including the frontmatter. The shrunk command only runs `jj root` and `bash <installer>`, so `allowed-tools` must gain `Bash(bash:*)` (no existing pattern matches a command whose leading token is `bash` — `agent-helpers-setup.md` sets this precedent) and shed the now-dead `cp`/`chmod`/`mkdir`/`cat`/`jq`/`ls`/`dirname`/`realpath`/`md5`/`sed`/`grep`/`Read`/`Write` entries (all internal to the installer now):

```markdown
---
description: Bootstrap jj (Jujutsu) workflow enforcement for this project
allowed-tools: Bash(jj:*), Bash(bash:*)
---
## Your Task

Bootstrap jj (Jujutsu) workflow enforcement for the current project: install the SessionStart / PreCompact / PreToolUse / Worktree hooks, jj permissions, and the CLAUDE.md VCS section.

**CRITICAL: This is a jj (Jujutsu) plugin. You MUST NOT use ANY raw git commands — always use jj equivalents. The only exceptions are `jj git` subcommands and `gh` CLI.**

## Steps

### Step 1: Gate on a jj repo

Run `jj root`. If it fails, tell the user `/project-setup` requires a jj repository and stop. Otherwise capture the project root.

### Step 2: Run the installer

All install work is done by a deterministic script — do not hand-merge settings or edit CLAUDE.md yourself. Run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/project-setup-install.sh" "${CLAUDE_PLUGIN_ROOT}" "$(jj root)"
```

The script copies the four hook scripts into `.claude/scripts/`, deep-merges the hooks and permissions into `.claude/settings.local.json` (idempotently — re-running never duplicates entries and never touches unrelated config), and creates/updates the CLAUDE.md `## VCS` section. It prints a `key=value` summary and exits non-zero without writing if an existing `.claude/settings.local.json` is not valid JSON (in which case, report the error and stop — do not attempt to repair it automatically).

### Step 3: Report

Read the script's `key=value` summary and confirm to the user what was set up:

- Hook scripts installed in `.claude/scripts/` (SessionStart, require-jj-new, workspace create/remove)
- `.claude/settings.local.json` updated (SessionStart + PreCompact + PreToolUse + WorktreeCreate + WorktreeRemove hooks + jj permissions) — value from `settings=`
- CLAUDE.md — `created`, `updated`, or `already up to date` per the `claude_md=` value

Then remind the user to:
- **Restart Claude Code** for the hooks to take effect
- Optionally add `.claude/scripts/` to their ignore patterns if they don't want these tracked
```

- [ ] **Step 2: Bump the plugin version**

Edit `plugins/project-setup-jj/.claude-plugin/plugin.json`: `"version": "0.1.2"` → `"version": "0.1.3"`.

- [ ] **Step 3: Verify the plugin's suites and the version-bump lint**

Run:
```bash
for t in plugins/project-setup-jj/tests/test-*.sh; do echo "== $t =="; bash "$t" >/tmp/ps && echo PASS || { echo FAIL; tail -5 /tmp/ps; }; done
```
Expected: all PASS — `test-project-setup-install.sh`, `test-statusline-jj.sh`, `test-template-hash.sh`.

Run the version-bump lint:
```bash
BASE=$(mktemp -d); mkdir -p "$BASE/plugins/project-setup-jj/.claude-plugin"
jj file show -r @- plugins/project-setup-jj/.claude-plugin/plugin.json > "$BASE/plugins/project-setup-jj/.claude-plugin/plugin.json" 2>/dev/null || echo '{"version":"0.1.2"}' > "$BASE/plugins/project-setup-jj/.claude-plugin/plugin.json"
CHANGED_FILES="$(jj diff -r @ --name-only 2>/dev/null)$(printf '\nplugins/project-setup-jj/scripts/project-setup-install.sh')" BASE_DIR="$BASE" bash .github/scripts/require-version-bump.sh; echo "lint exit=$?"
```
Expected: `lint exit=0`.

- [ ] **Step 4: Commit (jj)**

```bash
jj describe -m "refactor(#78): shrink /project-setup command to call the installer

The command now gates on jj root, runs project-setup-install.sh via
\${CLAUDE_PLUGIN_ROOT}, and relays the key=value summary. The improvised-jq
merge prose is deleted. Bump project-setup-jj 0.1.2 -> 0.1.3."
jj new
```

---

## Self-Review

**Spec coverage:**
- Installer script — copies, 5-event merge, hook-granularity replace-by-identity, PreCompact value, permissions union, malformed abort, CLAUDE.md 4-case, key=value summary → Task 1, Step 3.
- Test (7 cases incl. co-located-user-hook + malformed) → Task 1, Step 1.
- Command shrink to gate → `${CLAUDE_PLUGIN_ROOT}` call → relay → Task 2, Step 1.
- Version bump 0.1.2→0.1.3 → Task 2, Step 2.
- `test-template-hash.sh` already covers the real template hash (spec §Component 3) → not re-tested here; Task 2 Step 3 confirms it still passes.

**Placeholder scan:** none — full script and test code inline; exact paths and commands throughout. (The fabricated template's literal `hash:PLACEHOLDER` is intentionally rewritten to the computed hash in the test's setup, not a plan placeholder.)

**Type/name consistency:** summary keys (`session_start`, `require_jj_new`, `workspace_hooks`, `settings`, `claude_md`, `restart_required`) match between the script (Task 1 Step 3), the test assertions (Task 1 Step 1), and the command's relay (Task 2 Step 1). Identity-match suffixes (`/.claude/scripts/<name>.sh`) match between the script's `upsert` calls and the test's `endswith` assertions.

**One watch-item for the implementer:** the `upsert` jq relies on `endswith` against the absolute destination path stored in settings; the test seeds stored commands with `$P/.claude/scripts/...` so the relative suffix matches. If a real consumer's stored path ever used a symlinked/relative form, identity could miss — acceptable for this iteration (the command always writes absolute paths).
