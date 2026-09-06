# Worktree Isolation Guard × jj — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a thread in a harness-isolated jj workspace finish unattended: `/finish` leaves the worktree before its remote phase, the session briefing warns at minute zero, the WorktreeCreate hook bases on trunk safely, and the README routes PR work to `jjtab`.

**Architecture:** Three independent plugin changes shipped as three PRs in order. project-setup-jj first (hooks + briefing + two test suites), then commit-commands-jj (`/finish` Step 3.5, Step 5 edits, prose-claims assertions), then workspace-jj (README only). Detection everywhere is path provenance: the current workspace root under `/tmp/jj-workspaces/` or `/private/tmp/jj-workspaces/`.

**Tech Stack:** bash 3.2-compatible shell (macOS CI), jj 0.44, jq, Claude Code hooks (SessionStart, WorktreeCreate, WorktreeRemove), Claude Code command markdown (`finish.md`).

**Spec:** `docs/superpowers/specs/2026-09-06-worktree-isolation-guard-design.md`

**Revision 2** (after a two-reviewer plan review that executed Part A in a scratch copy): Option 4 now always exits in a hook-made workspace; the op-id capture moved back into Option 4; the remove hook refuses paths outside the harness prefix; the session-start flag lint is tightened so the notice's own prose does not trip it; the prose-claims assertions pin ordering and `keep`; `jjtab` gained the `mkdir -p` it needed; the manual dry run moved ahead of any `finish.md` prose; Part A stacks on the spec change so the docs ship with PR 1.

## Global Constraints

- **jj, never git, in anything the model runs.** Test suites may use `git init --bare` for a file remote only inside their own sandbox (`env -i`, sandbox HOME), the pattern `test-command-prose-claims.sh` already uses.
- **bash 3.2 safe:** no `globstar`, no associative arrays, no `mapfile`, no `${var,,}`. Test with `/bin/bash`, not zsh.
- **Test isolation:** every suite isolates jj config — either `JJ_CONFIG` pointed at a scratch file, or `env -i` with a sandbox `HOME`/`XDG_CONFIG_HOME`. Never touch `~/.config/jj`.
- **Both prefix spellings, always:** `/tmp/jj-workspaces/` and `/private/tmp/jj-workspaces/`.
- **Both hook copies change:** `plugins/project-setup-jj/scripts/<hook>` (installer source) and `.claude/hooks/<hook>` (what this repo's `.claude/settings.json` runs). Copy plugin → repo with `cp` after every hook edit. Task A3 adds a CI assertion that the copies match.
- **Snapshot budget in `jj-session-start.sh`:** `jj status` is the only unflagged call; every other read carries `--ignore-working-copy` and appears after the `jj status` line.
- **Versions bump per plugin** in `plugins/<name>/.claude-plugin/plugin.json` only: project-setup-jj 0.19.2 → 0.20.0, commit-commands-jj 0.19.0 → 0.20.0, workspace-jj 0.4.0 → 0.5.0. CI fails a PR whose plugin bytes change without a bump. The root `README.md` is not under a plugin and needs no bump.
- **`sed -i` as written is GNU sed** (this machine is WSL). On macOS use `sed -i ''`.
- **Suite discovery is a glob:** any `plugins/<name>/tests/test-*.sh` is auto-run by CI. Run a suite locally with `bash <path>`.
- **Change IDs, not commit IDs**, for anything held across a step (`jj log -r <rev> --no-graph -T 'change_id.short()'`).
- **Serial SDD, default workspace.** One implementer at a time; each task ends with `jj describe` and the next begins with `jj new`.
- **Stacks.** Part A starts on the change holding the spec and this plan (`omuwnmsl`), so the docs ship with PR 1. Parts B and C each start with `jj git fetch` followed by `jj new 'trunk()'`, and Part B must not start until PR 1 has merged: its dry run calls the positional remove hook Part A installs.
- **Insert blocks with the Edit tool or a quoted heredoc (`<<'EOF'`).** Several blocks contain `$0`, `$1`, `$FIN`, `$PASS`; an unquoted heredoc expands them silently.

Run all suites:
```bash
for t in $(find plugins .github -path '*/tests/test-*.sh' | sort); do echo "== $t"; bash "$t" >/dev/null 2>&1 && echo PASS || echo "FAIL $t"; done
```

---

## Part A — project-setup-jj 0.20.0

Start the stack on the spec change:
```bash
jj new -m "wip(project-setup-jj): worktree hooks + isolation notice"
```
(`@` is `omuwnmsl`, the spec+plan change; `jj new` with no argument stacks on it.)

### Task 1 (A1): New suite + WorktreeCreate hook bases on `trunk() ~ root()`

**Files:**
- Create: `plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`
- Modify: `plugins/project-setup-jj/scripts/jj-workspace-create.sh` (whole file)
- Modify: `.claude/hooks/jj-workspace-create.sh` (copy of the above)

**Interfaces:**
- Consumes: the hooks' stdin contract — WorktreeCreate reads `{"name":..., "cwd":...}` and prints the absolute workspace path; WorktreeRemove reads `{"worktree_path":..., "cwd":...}`.
- Produces: a suite with helpers `ok`, `bad`, `new_repo`, `R`, `HOOK`, `seed_repo`, `park_change`, and variables `UNIQ`, `SCRIPTS`, `CREATE`, `REMOVE`, used again by Tasks A2 and A3. Workspaces are created under the real `/tmp/jj-workspaces/<UNIQ>/` and removed by the trap.

- [ ] **Step 1: Write the failing suite (create-hook arms only)**

```bash
cat > plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh <<'SUITE'
#!/usr/bin/env bash
# Behaviour tests for the WorktreeCreate / WorktreeRemove hooks.
#
# Why two arms for the create hook's base revision: `trunk()` does not FAIL in
# a repo with no remote — it resolves to the root commit, exit 0 — so
# `jj workspace add --revision trunk()` silently produces a workspace with no
# project files. A single with-origin arm is exactly the configuration under
# which that bug is invisible. Both arms therefore also assert the workspace
# CONTAINS the repo's files, not merely that its parent is the expected commit.
#
# Workspaces are created where the hook really puts them — the hook hardcodes
# /tmp/jj-workspaces/<basename cwd>/<name> — under a unique basename, and the
# trap removes that subtree. Nothing here touches a real project's workspaces.
#
# Isolation is `env -i` plus a sandbox HOME/XDG_CONFIG_HOME (the pattern
# commit-commands-jj's prose-claims suite uses), so jj never reads the
# caller's ~/.config/jj.
#
# bash 3.2 safe: no globstar, no associative arrays.
set -uo pipefail

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jj >/dev/null 2>&1; then
  printf 'FAIL - jj must be installed\n0 passed, 1 failed\n'; exit 1
fi

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)/scripts"
CREATE="$SCRIPTS/jj-workspace-create.sh"
REMOVE="$SCRIPTS/jj-workspace-remove.sh"

TMPROOT=$(mktemp -d)
# Unique basename so two concurrent runs (or a real project named "cwd") never
# share /tmp/jj-workspaces/<basename>.
UNIQ="hooktest-$$-$(date +%s)"
cleanup() { rm -rf "$TMPROOT" "/tmp/jj-workspaces/$UNIQ"; }
trap cleanup EXIT

# new_repo -> prints a sandbox root. The repo lives at <root>/<UNIQ> so the
# hook's basename(cwd) is UNIQ.
new_repo() {
  nr_root=$(mktemp -d "$TMPROOT/r.XXXXXX")
  mkdir -p "$nr_root/home/.config/jj" "$nr_root/$UNIQ"
  printf '[user]\nname = "test"\nemail = "test@example.com"\n\n[ui]\npaginate = "never"\neditor = "true"\n' \
    > "$nr_root/home/.config/jj/config.toml"
  printf '%s\n' "$nr_root"
}
# R <root> cmd... : run inside the sandbox repo dir with a clean environment.
R() { r_root="$1"; shift; ( cd "$r_root/$UNIQ" && env -i PATH="$PATH" \
    HOME="$r_root/home" USERPROFILE="$r_root/home" \
    XDG_CONFIG_HOME="$r_root/home/.config" TMPDIR="${TMPDIR:-/tmp}" \
    TERM=dumb "$@" ); }
# HOOK <root> <hook> <json> : run a hook the way the harness does — JSON on
# stdin, sandboxed environment, cwd = the repo.
HOOK() { h_root="$1"; h_script="$2"; h_json="$3"; ( cd "$h_root/$UNIQ" && printf '%s' "$h_json" | env -i PATH="$PATH" \
    HOME="$h_root/home" USERPROFILE="$h_root/home" \
    XDG_CONFIG_HOME="$h_root/home/.config" TMPDIR="${TMPDIR:-/tmp}" \
    TERM=dumb bash "$h_script" ); }

# Seed: README.md at main.
seed_repo() {
  s_root="$1"
  R "$s_root" jj git init . >/dev/null 2>&1
  printf 'hello\n' > "$s_root/$UNIQ/README.md"
  R "$s_root" jj describe -m "Initial commit" >/dev/null 2>&1
  R "$s_root" jj bookmark create main -r @ >/dev/null 2>&1
}
# Put a described, non-empty change between main and @ so `@-` is NOT trunk.
park_change() {
  p_root="$1"
  R "$p_root" jj new main >/dev/null 2>&1
  printf 'parked\n' > "$p_root/$UNIQ/parked.txt"
  R "$p_root" jj describe -m "parked work" >/dev/null 2>&1
  R "$p_root" jj new >/dev/null 2>&1
}

# ---------------------------------------------------------------- create hook
# Arm 1: origin exists, trunk() is real. Expect parent == trunk, files present.
root=$(new_repo)
seed_repo "$root"
printf 'origin.git/\n' > "$root/$UNIQ/.gitignore"
R "$root" git init --bare --quiet origin.git
R "$root" jj git remote add origin "$root/$UNIQ/origin.git" >/dev/null 2>&1
R "$root" jj git push --bookmark main >/dev/null 2>&1
park_change "$root"
trunk_id=$(R "$root" jj log -r 'trunk()' --no-graph -T 'commit_id')
parked_id=$(R "$root" jj log -r '@-' --no-graph -T 'commit_id')
if [ "$trunk_id" = "$parked_id" ]; then
  bad "fixture: @- equals trunk, the with-origin arm cannot distinguish the bases"
fi
ws=$(HOOK "$root" "$CREATE" "{\"name\":\"probe\",\"cwd\":\"$root/$UNIQ\"}" 2>/dev/null)
if [ "$ws" = "/tmp/jj-workspaces/$UNIQ/probe" ]; then
  ok "create hook prints the workspace path"
else
  bad "create hook printed '$ws', expected /tmp/jj-workspaces/$UNIQ/probe"
fi
ws_parent=$(R "$root" jj -R "$ws" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)
if [ -n "$ws_parent" ] && [ "$ws_parent" = "$trunk_id" ]; then
  ok "with origin: workspace parent is trunk(), not the parked @-"
else
  bad "with origin: workspace parent is '$ws_parent', trunk is '$trunk_id', parked @- is '$parked_id'"
fi
if [ -f "$ws/README.md" ]; then
  ok "with origin: workspace contains the repo's files"
else
  bad "with origin: README.md missing from the workspace — an empty tree (root-commit base?)"
fi
HOOK "$root" "$REMOVE" "{\"worktree_path\":\"$ws\",\"cwd\":\"$root/$UNIQ\"}" >/dev/null 2>&1

# Arm 2: no remote. trunk() would be root(). Expect fallback to @-, files present.
root2=$(new_repo)
seed_repo "$root2"
park_change "$root2"
parked2=$(R "$root2" jj log -r '@-' --no-graph -T 'commit_id')
ws2=$(HOOK "$root2" "$CREATE" "{\"name\":\"probe2\",\"cwd\":\"$root2/$UNIQ\"}" 2>/dev/null)
ws2_parent=$(R "$root2" jj -R "$ws2" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)
if [ -n "$ws2_parent" ] && [ "$ws2_parent" = "$parked2" ]; then
  ok "no remote: workspace falls back to @- (trunk() would have been the root commit)"
else
  bad "no remote: workspace parent is '$ws2_parent', expected @- '$parked2'"
fi
if [ -f "$ws2/README.md" ] && [ -f "$ws2/parked.txt" ]; then
  ok "no remote: workspace contains the repo's files"
else
  bad "no remote: files missing from the workspace — root-commit base leaked through"
fi
HOOK "$root2" "$REMOVE" "{\"worktree_path\":\"$ws2\",\"cwd\":\"$root2/$UNIQ\"}" >/dev/null 2>&1

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
SUITE
chmod +x plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh
```

- [ ] **Step 2: Run it and confirm the with-origin arm fails**

Run: `bash plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`
Expected (verified in review): `FAIL - with origin: workspace parent is '<parked>', trunk is ...`; the other four `ok`; `4 passed, 1 failed`; exit 1.

- [ ] **Step 3: Rewrite the create hook**

```bash
cat > plugins/project-setup-jj/scripts/jj-workspace-create.sh <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# WorktreeCreate hook: create a jj workspace for Claude Code worktree isolation.
# Input (stdin): JSON with "name" and "cwd" fields
# Output (stdout): absolute path of the created workspace directory
#
# Hooks win: when WorktreeCreate is configured, `claude --worktree` and
# `EnterWorktree` call this even in a colocated repo — measured 2026-09-06.
# The session that lands here is worktree-ISOLATED: the harness refuses every
# `jj git` command inside it (it reads the `git` token as a git invocation).
# The SessionStart briefing says so; /finish leaves the worktree before pushing.

input=$(cat)
name=$(echo "$input" | jq -r '.name')
cwd=$(echo "$input" | jq -r '.cwd')

# Create the workspace OUTSIDE the repo so jj's auto-snapshot in the default
# workspace never attributes workspace edits to the default @. /tmp is not
# under any repo root. (macOS reports this path back as /private/tmp/...;
# every consumer matches both spellings.)
DIR="/tmp/jj-workspaces/$(basename "$cwd")/$name"
mkdir -p "$(dirname "$DIR")"

# Base revision: trunk, guarded — then @-, then jj's default.
#
# Why trunk and not @-: a thread based on @- inherits whatever is parked on
# the default workspace, including an undescribed empty change that later
# blocks `jj git push`. trunk never carries that.
#
# Why `trunk() ~ root()` and not `trunk()`: in a repo with no remote trunk()
# does not fail — it resolves to the ROOT COMMIT with exit 0, and a workspace
# added there has no project files at all. Subtracting root() turns that case
# into an empty string, which is the signal the fallback below needs. A local
# `main` that is ahead of origin (merged locally, push not yet asked for) is a
# transient state; a deliberate stacked follow-up on current context is
# `jjtab <name> '@-'` territory, not this hook's.
base=$(jj -R "$cwd" log -r 'trunk() ~ root()' --no-graph -T 'commit_id' 2>/dev/null || true)
if [ -z "$base" ]; then
  base=$(jj -R "$cwd" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null || true)
fi

if [ -n "$base" ]; then
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" --revision "$base" >&2
else
  # Nothing resolved (empty repo?): let jj pick.
  jj -R "$cwd" workspace add "$DIR" --name "workspace-$name" >&2
fi

echo "$DIR"
HOOK
chmod +x plugins/project-setup-jj/scripts/jj-workspace-create.sh
cp plugins/project-setup-jj/scripts/jj-workspace-create.sh .claude/hooks/jj-workspace-create.sh
```

- [ ] **Step 4: Run the suite and confirm both arms pass**

Run: `bash plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`
Expected (verified in review): `5 passed, 0 failed`, exit 0.

- [ ] **Step 5: Confirm the two copies are identical and record the change**

```bash
cmp plugins/project-setup-jj/scripts/jj-workspace-create.sh .claude/hooks/jj-workspace-create.sh && echo SAME
jj describe -m "feat(project-setup-jj): WorktreeCreate bases on trunk() ~ root(), falls back to @-; new hook suite"
jj new
```

### Task 2 (A2): WorktreeRemove hook takes positional arguments, derives names correctly, refuses foreign paths

**Files:**
- Modify: `plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh` (append a section before the final summary)
- Modify: `plugins/project-setup-jj/scripts/jj-workspace-remove.sh` (whole file)
- Modify: `.claude/hooks/jj-workspace-remove.sh` (copy)

**Interfaces:**
- Consumes: Task A1's suite helpers (`new_repo`, `R`, `HOOK`, `seed_repo`, `UNIQ`, `CREATE`, `REMOVE`).
- Produces: `jj-workspace-remove.sh <worktree_path> <cwd>` — positional form used by `/finish` in Part B. Stdin JSON form unchanged for the harness. Registry name derived from the path relative to `/tmp/jj-workspaces/<repo>/` (or `/private/tmp/...`), prefixed `workspace-`. A trailing slash is stripped. A path outside the harness prefix is refused with exit 2 and nothing is removed.

- [ ] **Step 1: Append the failing remove-hook assertions**

Insert the block below immediately **above** the line `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` in `plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh` (Edit tool or quoted heredoc):

```bash
# ---------------------------------------------------------------- remove hook
# Positional form: `remove.sh <worktree_path> <cwd>`. /finish calls this from
# the main checkout after ExitWorktree, where a stdin JSON pipe is a compound
# command outside its allowed-tools; a plain command with two arguments is not.
# `</dev/null` on every positional call: the OLD hook reads stdin, and a
# developer running this suite from a terminal would otherwise hang there.
root3=$(new_repo)
seed_repo "$root3"
ws3=$(HOOK "$root3" "$CREATE" "{\"name\":\"pos\",\"cwd\":\"$root3/$UNIQ\"}" 2>/dev/null)
R "$root3" bash "$REMOVE" "$ws3" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
if R "$root3" jj workspace list 2>/dev/null | grep -q '^workspace-pos:'; then
  bad "positional remove: workspace-pos still registered"
else
  ok "positional remove: workspace forgotten"
fi
if [ -e "$ws3" ]; then
  bad "positional remove: directory still exists: $ws3"
else
  ok "positional remove: directory removed"
fi

# JSON form still works (the harness sends this shape).
ws4=$(HOOK "$root3" "$CREATE" "{\"name\":\"json\",\"cwd\":\"$root3/$UNIQ\"}" 2>/dev/null)
HOOK "$root3" "$REMOVE" "{\"worktree_path\":\"$ws4\",\"cwd\":\"$root3/$UNIQ\"}" >/dev/null 2>&1
if R "$root3" jj workspace list 2>/dev/null | grep -q '^workspace-json:'; then
  bad "json remove: workspace-json still registered"
else
  ok "json remove: workspace forgotten (stdin contract intact)"
fi

# Slash-separated names. EnterWorktree allows `feat/auth`; the create hook
# registers `workspace-feat/auth`. A basename-derived forget targets
# `workspace-auth`, fails silently, and the directory is removed anyway —
# leaving a registration that points at nothing.
ws5=$(HOOK "$root3" "$CREATE" "{\"name\":\"feat/auth\",\"cwd\":\"$root3/$UNIQ\"}" 2>/dev/null)
if R "$root3" jj workspace list 2>/dev/null | grep -q '^workspace-feat/auth:'; then
  ok "fixture: slash name registered as workspace-feat/auth"
else
  bad "fixture: slash name not registered as expected: $(R "$root3" jj workspace list 2>/dev/null)"
fi
R "$root3" bash "$REMOVE" "$ws5" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
if R "$root3" jj workspace list 2>/dev/null | grep -q '^workspace-feat/auth:'; then
  bad "slash name: workspace-feat/auth still registered after remove (basename bug)"
else
  ok "slash name: workspace-feat/auth forgotten"
fi
if [ -e "$ws5" ]; then
  bad "slash name: directory still exists: $ws5"
else
  ok "slash name: directory removed"
fi

# Trailing slash: a model-typed path may carry one; `workspace-probe/` is not
# a registry name.
ws6=$(HOOK "$root3" "$CREATE" "{\"name\":\"slash\",\"cwd\":\"$root3/$UNIQ\"}" 2>/dev/null)
R "$root3" bash "$REMOVE" "$ws6/" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
if R "$root3" jj workspace list 2>/dev/null | grep -q '^workspace-slash:'; then
  bad "trailing slash: workspace-slash still registered"
else
  ok "trailing slash: workspace forgotten"
fi
if [ -e "$ws6" ]; then
  bad "trailing slash: directory still exists: $ws6"
else
  ok "trailing slash: directory removed"
fi

# Prefix guard: the script ends in `rm -rf`, and /finish now supplies the path.
# Anything outside /tmp/jj-workspaces/<repo>/ must be refused, untouched.
outside="$root3/$UNIQ/not-a-workspace"
mkdir -p "$outside"
R "$root3" bash "$REMOVE" "$outside" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "prefix guard: path outside the harness prefix refused with exit 2"
else
  bad "prefix guard: expected exit 2 for $outside, got $rc"
fi
if [ -d "$outside" ]; then
  ok "prefix guard: refused path left untouched"
else
  bad "prefix guard: the script removed a directory outside /tmp/jj-workspaces"
fi
```

- [ ] **Step 2: Run and confirm the positional, slash, trailing-slash and guard cases fail**

Run: `bash plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`
Expected: the old hook reads empty stdin, `jq` yields nothing, so nothing is forgotten or removed on the positional calls and it exits 0 on the foreign path. `8 passed, 7 failed` (A1's 5, `json remove`, `fixture: slash name`, and `prefix guard: refused path left untouched` pass). Exit 1.

- [ ] **Step 3: Rewrite the remove hook**

```bash
cat > plugins/project-setup-jj/scripts/jj-workspace-remove.sh <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# WorktreeRemove hook: forget and remove a jj workspace the create hook made.
#
# Two calling forms:
#   harness:  JSON on stdin — {"worktree_path": ..., "cwd": ...}
#   /finish:  positional — jj-workspace-remove.sh <worktree_path> <cwd>
# The positional form exists because /finish runs this from the MAIN checkout
# after ExitWorktree (the WorktreeRemove hook no longer fires for a worktree the
# session has already left), and a plain two-argument command fits its
# allowed-tools where a stdin pipe would not.

if [ "$#" -ge 2 ]; then
  workspace_path="$1"
  cwd="$2"
else
  input=$(cat)
  workspace_path=$(echo "$input" | jq -r '.worktree_path')
  cwd=$(echo "$input" | jq -r '.cwd')
fi

if [ -z "$workspace_path" ] || [ "$workspace_path" = "null" ]; then
  echo "jj-workspace-remove: no worktree_path given" >&2
  exit 2
fi
workspace_path="${workspace_path%/}"

# This script ends in `rm -rf`, and since /finish can now supply the path it
# refuses anything that is not a harness workspace. Both /tmp spellings; the
# path must have a <repo>/<name> tail.
case "$workspace_path" in
  /tmp/jj-workspaces/*/*|/private/tmp/jj-workspaces/*/*) ;;
  *) echo "jj-workspace-remove: refusing a path outside /tmp/jj-workspaces/<repo>/: $workspace_path" >&2
     exit 2 ;;
esac

# Registry name = "workspace-" + the path RELATIVE to /tmp/jj-workspaces/<repo>/.
# Not basename: the create hook registers `workspace-<name>` for the full
# name, and EnterWorktree allows slash-separated names (`feat/auth`), so
# basename would forget `workspace-auth` — a miss, swallowed — and then remove
# the directory anyway, leaving a registration that points at nothing.
rel="${workspace_path#/private}"
rel="${rel#/tmp/jj-workspaces/}"
name="${rel#*/}"                      # drop the <repo> segment

# Forget first (a failure here is not fatal — the workspace may already be
# forgotten), then remove the directory.
jj -R "$cwd" workspace forget "workspace-$name" 2>/dev/null || true
rm -rf "$workspace_path"
HOOK
chmod +x plugins/project-setup-jj/scripts/jj-workspace-remove.sh
cp plugins/project-setup-jj/scripts/jj-workspace-remove.sh .claude/hooks/jj-workspace-remove.sh
```

- [ ] **Step 4: Run the suite; all green**

Run: `bash plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`
Expected: `15 passed, 0 failed` (5 from A1 + 10 here), exit 0.

- [ ] **Step 5: Record the change**

```bash
cmp plugins/project-setup-jj/scripts/jj-workspace-remove.sh .claude/hooks/jj-workspace-remove.sh && echo SAME
jj describe -m "fix(project-setup-jj): WorktreeRemove takes positional args, derives the registry name from the path, refuses foreign paths"
jj new
```

### Task 3 (A3): Session-start briefing emits the worktree-isolation notice; repo-copy parity guard

**Files:**
- Modify: `plugins/project-setup-jj/tests/test-jj-session-start.sh` (tighten the flag lint's invocation match; append three cases)
- Modify: `plugins/project-setup-jj/scripts/jj-session-start.sh` (one read + one block)
- Modify: `.claude/hooks/jj-session-start.sh` (re-sync by copy; it is already behind the plugin source)
- Modify: `plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh` (append the parity guard)

**Interfaces:**
- Consumes: the session-start suite's `ctx`, `ok`, `bad`, `WORK`, `HOOK`; the hook suite's `ok`, `bad`, `SCRIPTS`.
- Produces: a briefing block headed `== Worktree isolation ==`, present only when the current workspace root matches `/tmp/jj-workspaces/*` or `/private/tmp/jj-workspaces/*`; a CI assertion that the three repo hook copies equal the plugin source.

- [ ] **Step 1: Tighten the flag lint so prose is not read as an invocation**

The lint's substring arm `*'! jj '*` exists to catch `if ! jj root`. The new notice's prose ends with `` `! jj git ...` `` and would be reported as an unflagged call. Move the `! jj` forms to the command-position arm. In `plugins/project-setup-jj/tests/test-jj-session-start.sh`, replace:

```bash
  case "$line" in
    *'$(jj '*|*'! jj '*) invocation=1 ;;
  esac
  case "$trimmed" in
    'jj '*) invocation=1 ;;
  esac
```

with:

```bash
  case "$line" in
    *'$(jj '*) invocation=1 ;;
  esac
  case "$trimmed" in
    'jj '*|'if ! jj '*|'! jj '*) invocation=1 ;;
  esac
```

Run: `bash plugins/project-setup-jj/tests/test-jj-session-start.sh` — Expected: unchanged, all pass (the lint still sees `if ! jj root` at command position).

- [ ] **Step 2: Append the failing cases**

Insert the block below immediately **above** the comment line `# --- a broken environment must not read as clean ---`:

```bash
# --- worktree isolation notice ---
# A workspace the WorktreeCreate hook made lives under /tmp/jj-workspaces/, and
# a session started there is harness-isolated: every `jj git` command is
# refused. The briefing says so at minute zero, from the root path alone (no
# env var marks isolation — measured on 2.1.263). Three cases: the hook's
# location -> notice; default workspace -> no notice; a sibling-directory
# workspace (jjtab) -> no notice. On macOS the first case runs under the
# /private/tmp spelling for free, since jj canonicalises the root.
cd "$WORK/repo"
ISO_UNIQ="ssprobe-$$-$(date +%s)"
ISO_ROOT="/tmp/jj-workspaces/$ISO_UNIQ"
cleanup_iso() { rm -rf "$ISO_ROOT"; rm -rf "$WORK"; }
trap cleanup_iso EXIT
mkdir -p "$ISO_ROOT"
jj workspace add "$ISO_ROOT/probe" --name workspace-probe -r 'trunk()' >/dev/null 2>&1
out_iso="$(cd "$ISO_ROOT/probe" && bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || true)"
case "$out_iso" in
  *"== Worktree isolation =="*"ExitWorktree"*) ok "hook-made workspace: briefing carries the isolation notice naming ExitWorktree" ;;
  *) bad "isolation notice" "missing from a workspace under $ISO_ROOT: $(printf '%s' "$out_iso" | grep -i -c isolation) isolation line(s)" ;;
esac
out_default="$(ctx)"
case "$out_default" in
  *"== Worktree isolation =="*) bad "isolation notice" "emitted in the DEFAULT workspace" ;;
  *) ok "default workspace: no isolation notice" ;;
esac
jj workspace add "$WORK/repo-sibling" --name sibling -r 'trunk()' >/dev/null 2>&1
out_sib="$(cd "$WORK/repo-sibling" && bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || true)"
case "$out_sib" in
  *"== Worktree isolation =="*) bad "isolation notice" "emitted in a sibling-directory (jjtab-style) workspace" ;;
  *) ok "sibling workspace: no isolation notice" ;;
esac
jj workspace forget workspace-probe >/dev/null 2>&1
jj workspace forget sibling >/dev/null 2>&1
```

- [ ] **Step 3: Run and confirm the first new case fails**

Run: `bash plugins/project-setup-jj/tests/test-jj-session-start.sh`
Expected (verified in review): `FAIL: isolation notice — missing from a workspace under /tmp/jj-workspaces/ssprobe-...`; the two negative cases and every pre-existing assertion pass; `29 passed, 1 failed`; exit 1.

- [ ] **Step 4: Add the read and the block to the hook**

In `plugins/project-setup-jj/scripts/jj-session-start.sh`, insert the following immediately **after** the `identity=$(...)` line (after the `jj status` snapshot point, as the ordering lint requires):

```bash
# Harness worktree isolation. A workspace the WorktreeCreate hook made lives
# under /tmp/jj-workspaces/, and a session started there is ISOLATED: Claude
# Code refuses every `jj git` command in it (it reads the `git` token as a git
# invocation and has no notion of jj), and most compound shell commands. No
# environment variable marks this — measured on 2.1.263 — so the root path is
# the only tell. Saying it here turns three refused pushes into zero surprises.
#
# This reintroduces a `jj workspace root` call, which the workspace section
# above deliberately retired. That retirement was about COMPARING this path to
# each row's recorded `self.root()`, which is empty for pre-0.38.0 and moved
# workspaces. This is a prefix test on the live path alone — no recorded path
# is involved, so the unsoundness does not apply. macOS reports /tmp as
# /private/tmp; both spellings are matched.
#
# Limit: SessionStart does not re-run on a mid-session EnterWorktree. That
# case is covered by /finish, which leaves the worktree before pushing.
ws_root=$(jj --ignore-working-copy workspace root 2>/dev/null || true)
isolation_note=""
case "$ws_root" in
  /tmp/jj-workspaces/*|/private/tmp/jj-workspaces/*)
    isolation_note="
== Worktree isolation ==
This workspace was created by the WorktreeCreate hook, so the harness guard
is active: every \`jj git\` command (push, fetch, remote) will be refused here,
and so will compound shell commands (pipes, &&, subshells). Before any remote
step, call ExitWorktree with action keep and continue from the main checkout;
bookmarks and changes are repo-global. Or hand the command to the user as
\`! jj git ...\`.
" ;;
esac
```

Then change the `context="..."` assembly so the note follows the Workspaces section. Replace:

```bash
Workspaces:
${workspaces}

Working copy status:
```

with:

```bash
Workspaces:
${workspaces}
${isolation_note}
Working copy status:
```

- [ ] **Step 5: Run the session-start suite; all green including the lints**

Run: `bash plugins/project-setup-jj/tests/test-jj-session-start.sh`
Expected (verified in review with the Step 1 lint change): the three new cases `PASS`; `every jj read except the probe and the snapshot point carries --ignore-working-copy` PASS; `lint saw the expected shape (6 flagged reads + a snapshot point)` PASS; `snapshot point precedes every --ignore-working-copy read` PASS; op-count cases unchanged; `30 passed, 0 failed`; exit 0.

- [ ] **Step 6: Re-sync the repo's own copy and add the parity guard**

```bash
cp plugins/project-setup-jj/scripts/jj-session-start.sh .claude/hooks/jj-session-start.sh
cmp plugins/project-setup-jj/scripts/jj-session-start.sh .claude/hooks/jj-session-start.sh && echo SAME
```

Expected: `SAME`. The diff of `.claude/hooks/jj-session-start.sh` will also carry the `current_working_copy()` marker rewrite the repo copy was missing; that is intended.

Then insert the block below immediately **above** the line `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` in `plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`:

```bash
# ---------------------------------------------------------------- repo copies
# This repo runs its OWN copies of these hooks from .claude/hooks/ (that is
# what .claude/settings.json points at), and nothing else compares them to the
# plugin source: test-script-copy-parity.sh sweeps plugins/*/scripts/ only.
# The session-start copy had drifted by a whole rewrite before this guard
# existed. Skips (does not fail) when run outside the plugins checkout.
REPO_HOOKS="$(cd "$(dirname "$0")/../../.." && pwd)/.claude/hooks"
for f in jj-workspace-create.sh jj-workspace-remove.sh jj-session-start.sh; do
  if [ ! -f "$REPO_HOOKS/$f" ]; then
    ok "repo copy of $f not present here (not the plugins checkout) — skipped"
  elif cmp -s "$SCRIPTS/$f" "$REPO_HOOKS/$f"; then
    ok "repo copy of $f matches the plugin source"
  else
    bad "repo copy .claude/hooks/$f has drifted from plugins/project-setup-jj/scripts/$f — cp the plugin copy over it"
  fi
done
```

Run: `bash plugins/project-setup-jj/tests/test-jj-workspace-hooks.sh`
Expected: `18 passed, 0 failed`, the last three being `repo copy of ... matches the plugin source`.

- [ ] **Step 7: Record the change**

```bash
jj describe -m "feat(project-setup-jj): SessionStart briefing warns when the workspace is harness-isolated; tighten flag lint; repo-copy parity guard"
jj new
```

### Task 4 (A4): project-setup-jj docs, version bump, full suite, PR

**Files:**
- Modify: `plugins/project-setup-jj/README.md:73-74` (hook table rows)
- Modify: `plugins/project-setup-jj/.claude-plugin/plugin.json:4` (version)

- [ ] **Step 1: Update the hook table rows**

Replace these two rows in `plugins/project-setup-jj/README.md`:

```markdown
| `.claude/hooks/jj-workspace-create.sh` | WorktreeCreate hook — creates jj workspace for worktree isolation |
| `.claude/hooks/jj-workspace-remove.sh` | WorktreeRemove hook — cleans up jj workspace |
```

with:

```markdown
| `.claude/hooks/jj-workspace-create.sh` | WorktreeCreate hook — creates the jj workspace for `claude --worktree` / `EnterWorktree` under `/tmp/jj-workspaces/<repo>/<name>`, based on `trunk()` (falls back to `@-` in a repo with no remote, where `trunk()` would be the root commit). A session in such a workspace is **harness-isolated**: every `jj git` command is refused there — the SessionStart briefing says so, and `/finish` leaves the worktree before pushing |
| `.claude/hooks/jj-workspace-remove.sh` | WorktreeRemove hook — forgets the workspace and removes the directory. Also callable as `jj-workspace-remove.sh <worktree_path> <cwd>` (used by `/finish` after ExitWorktree); refuses any path outside `/tmp/jj-workspaces/` |
```

- [ ] **Step 2: Bump the version**

```bash
sed -i 's/"version": "0.19.2"/"version": "0.20.0"/' plugins/project-setup-jj/.claude-plugin/plugin.json
grep -n '"version"' plugins/project-setup-jj/.claude-plugin/plugin.json
```

Expected: `4:  "version": "0.20.0",`

- [ ] **Step 3: Run every suite**

Run the "Run all suites" loop from Global Constraints.
Expected: every line `PASS`.

- [ ] **Step 4: Record and open the PR**

```bash
jj describe -m "chore(project-setup-jj): 0.20.0 — worktree hooks (trunk base, positional remove, prefix guard) + isolation notice"
```

Run `/finish`, option 1. Title: `feat(project-setup-jj): worktree hooks base on trunk(), WorktreeRemove positional args, SessionStart isolation notice`. The ancestor check will list the spec+plan change and Tasks A1–A3; they are this work — push them together.

PR body notes: other projects (tokotoko) need `/project-setup` re-run to receive the new hooks. This repo's `.claude/hooks/` copies are updated in the PR itself.

---

## Part B — commit-commands-jj 0.20.0

**Precondition:** PR 1 merged. Then:
```bash
jj git fetch
jj new 'trunk()' -m "wip(commit-commands-jj): /finish leaves a harness worktree before pushing"
```

### Task 5 (B0): Manual dry run of the exit sequence (human-run, before any prose)

**Files:** none changed. The user runs this in a separate terminal from the repo root; the implementer waits for the result.

- [ ] **Step 1: Launch a guarded session and record the refusal**

```bash
claude --worktree finish-dryrun
```

Inside it, in order:

1. Confirm the briefing shows `== Worktree isolation ==` (Part A shipped).
2. `jj status` — passes.
3. `jj git remote list` — **refused**, "This session is isolated in the worktree ...".

- [ ] **Step 2: Exit and prove the remote phase clears**

4. Ask Claude: "call ExitWorktree with action keep". Reply must be "Exited worktree. Your work is preserved at /tmp/jj-workspaces/claude-plugins/finish-dryrun. Session is now back in /home/muloka/pt/claude-plugins."
5. `jj workspace root` → `/home/muloka/pt/claude-plugins`.
6. `jj bookmark create dryrun-probe -r 'trunk()'` then `jj git push --bookmark dryrun-probe` — passes (a real push of a throwaway branch pointing at trunk).
7. A compound command clears: `cat <<'EOF' | wc -l` with two lines of text.
8. `jj bookmark delete dryrun-probe` then `jj git push --deleted` — passes; the throwaway branch is gone.
9. `.claude/hooks/jj-workspace-remove.sh /tmp/jj-workspaces/claude-plugins/finish-dryrun /home/muloka/pt/claude-plugins` then `jj workspace list` — only `default` remains.

- [ ] **Step 3: Gate**

If any of 4–9 differs from the expectation, stop: Step 3.5's prose is built on exactly those results, and the spec's Background must be corrected before Task B2. Otherwise record the outcome in the Part B PR body.

### Task 6 (B1): Prose-claims assertions for the new `/finish` structure

**Files:**
- Modify: `plugins/commit-commands-jj/tests/test-command-prose-claims.sh` (append before the final `printf`)

**Interfaces:**
- Consumes: the suite's `ok`, `bad`, `CMDS`.
- Produces: six assertions Tasks B2 and B3 must satisfy: (1) `## Step 3.5` heading precedes `## Step 4: Execute choice`; (2) Step 3.5 names `ExitWorktree`; (3) no fenced line in Step 3.5 *starts with* `jj git`; (4) Step 3.5 pins `action: "keep"` and never says `action: "remove"` or `discard_changes`; (5) the phrase `is the user asking to leave the worktree` occurs inside Step 3.5 (whitespace-insensitive); (6) the phrase `left in Step 3.5` appears in both the Step 5 section and the Important Rules section.

- [ ] **Step 1: Append the failing assertions (quoted heredoc or Edit tool)**

Insert the block below immediately **above** the line `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` in `plugins/commit-commands-jj/tests/test-command-prose-claims.sh`:

```bash
# --- finish.md Step 3.5 (worktree isolation, spec 2026-09-06). A session in a
# hook-made workspace (/tmp/jj-workspaces/) is harness-isolated: every `jj git`
# command is refused. finish.md leaves the worktree (ExitWorktree keep) BEFORE
# its first remote command, and only because the user's option choice is the
# ask — the tool's own text says "only when the user asks". Six claims:
#
#   (1) "## Step 3.5" comes before "## Step 4: Execute choice" — the exit
#       precedes every option's remote command by construction;
#   (2) Step 3.5 names ExitWorktree;
#   (3) no fenced line in Step 3.5 STARTS WITH `jj git` — the remote commands
#       stay in the options, after the exit (a prose mention inside a fence is
#       not an instruction to run one);
#   (4) Step 3.5 pins action: "keep" and never says remove/discard_changes —
#       remove destroys the change (spec: #85118);
#   (5) the sentence declaring the option choice as the user's ask sits inside
#       Step 3.5 (checked whitespace-insensitively: markdown reflows);
#   (6) the never-remove-the-directory rule carries the SAME exception in both
#       places it is stated (Step 5 and Important Rules).
FIN="$CMDS/finish.md"
section() { awk -v h="$2" -v n="$3" '$0 ~ "^"h{f=1;next} $0 ~ "^"n{f=0} f' "$1"; }
l35=$(grep -n '^## Step 3.5' "$FIN" | head -1 | cut -d: -f1)
l4=$(grep -n '^## Step 4: Execute choice' "$FIN" | head -1 | cut -d: -f1)
if [ -n "$l35" ] && [ -n "$l4" ] && [ "$l35" -lt "$l4" ]; then
  ok "finish.md: '## Step 3.5' precedes '## Step 4: Execute choice'"
else
  bad "finish.md: no '## Step 3.5' heading before '## Step 4: Execute choice' (l35='$l35' l4='$l4')"
fi
s35=$(section "$FIN" '## Step 3.5' '## Step 4')
if [ -z "$s35" ]; then
  bad "finish.md has no Step 3.5 section — four assertions skipped"
else
  if printf '%s\n' "$s35" | grep -q 'ExitWorktree'; then
    ok "finish.md Step 3.5 names ExitWorktree"
  else
    bad "finish.md Step 3.5 never names ExitWorktree"
  fi
  if printf '%s\n' "$s35" | awk '/^[[:space:]]*```/{inb=!inb; next} inb' | grep -qE '^[[:space:]]*(\$ )?jj git'; then
    bad "finish.md Step 3.5 executes a 'jj git' command — that runs BEFORE the exit and will be refused"
  else
    ok "finish.md Step 3.5 holds no executable 'jj git' (remote commands come after the exit)"
  fi
  if printf '%s\n' "$s35" | grep -qF 'action: "keep"' \
     && ! printf '%s\n' "$s35" | grep -qEi 'action: "remove"|discard_changes'; then
    ok "finish.md Step 3.5 exits with keep, never remove/discard"
  else
    bad "finish.md Step 3.5 does not pin ExitWorktree to keep — remove destroys the change (spec: #85118)"
  fi
  if printf '%s\n' "$s35" | tr '\n' ' ' | tr -s ' ' | grep -qF 'is the user asking to leave the worktree'; then
    ok "finish.md Step 3.5 states that the option choice is the user's ask to leave the worktree"
  else
    bad "finish.md Step 3.5 lacks the sentence making the option choice the user's ask (ExitWorktree's own text forbids proactive calls)"
  fi
fi
s5=$(section "$FIN" '## Step 5' '## Quick Reference')
rules=$(section "$FIN" '## Important Rules' '## Integration')
if printf '%s\n' "$s5" | grep -qF 'left in Step 3.5' && printf '%s\n' "$rules" | grep -qF 'left in Step 3.5'; then
  ok "finish.md never-remove rule carries the Step 3.5 exception in both Step 5 and Important Rules"
else
  bad "finish.md never-remove exception is missing from Step 5 or Important Rules (they must agree)"
fi
```

- [ ] **Step 2: Run and confirm the new assertions fail**

Run: `bash plugins/commit-commands-jj/tests/test-command-prose-claims.sh`
Expected: `FAIL - finish.md: no '## Step 3.5' heading ...`, `FAIL - finish.md has no Step 3.5 section — four assertions skipped`, `FAIL - finish.md never-remove exception is missing ...`. Every pre-existing assertion `ok`. Exit 1.

- [ ] **Step 3: Record the change**

```bash
jj describe -m "test(commit-commands-jj): prose-claims assertions for /finish Step 3.5 (fail first)"
jj new
```

### Task 7 (B2): `/finish` Step 3.5 — leave the harness worktree

**Files:**
- Modify: `plugins/commit-commands-jj/commands/finish.md` — line 3 (allowed-tools); insert Step 3.5 before `## Step 4: Execute choice`; a lead-in line under `## Step 4`; Option 1 step 1's revset tokens; Option 4 steps 1, 2 and 4

**Interfaces:**
- Consumes: Part A's `jj-workspace-remove.sh <worktree_path> <cwd>` (referenced by Task B3, not here).
- Produces: the `## Step 3.5` section and the recorded values `<target-change-id>`, `<left-workspace-name>`, `<left-workspace-root>`, `<main-root>`, which Task B3's Step 5.0 consumes.

- [ ] **Step 1: Extend allowed-tools**

Replace line 3:

```
allowed-tools: Bash(jj:*), Bash(jj git push:*), Bash(gh pr create:*), Bash(gh pr view:*), AskUserQuestion, Read
```

with:

```
allowed-tools: Bash(jj:*), Bash(jj git push:*), Bash(gh pr create:*), Bash(gh pr view:*), Bash(.claude/hooks/jj-workspace-remove.sh:*), AskUserQuestion, Read, ExitWorktree
```

- [ ] **Step 2: Insert Step 3.5 before Step 4**

Insert the following immediately **before** the line `## Step 4: Execute choice`:

````markdown
## Step 3.5: Leave the harness worktree (isolated sessions only)

**Trigger — both must hold:**

1. The current workspace root (Context) is under `/tmp/jj-workspaces/` or
   `/private/tmp/jj-workspaces/`. That is a workspace the WorktreeCreate hook
   made (`claude --worktree`, `EnterWorktree`), and a session started in one
   is **harness-isolated**: Claude Code refuses every `jj git` command there
   (it reads the `git` token as a git invocation and has no notion of jj),
   and most compound shell commands.
2. The chosen option is 1, 2 or 4:

   | Option | Why it must leave the worktree |
   |---|---|
   | 1 push + PR | `jj git push`, `jj git fetch`, `jj git push --deleted` are all refused inside |
   | 2 merge into trunk locally | its step 1 `jj git fetch` is refused inside |
   | 3 keep | nothing to do — does **not** leave |
   | 4 discard | `jj git push --deleted` is refused inside if the bookmark was pushed; and even unpushed, forgetting a workspace from inside it leaves this session with no working copy (`jj status` → *No working copy*), unable to run the recovery it just handed back |

A durable root (a `jjtab` sibling directory, or anything else) never triggers
this step: there is no guard there.

**Selecting option 1, 2 or 4 in such a workspace is the user asking to leave the worktree; call ExitWorktree now.**
(Its description says not to call it proactively. The `/finish` choice is the ask.)

**Do, in this order, all inside the workspace:**

1. **Snapshot.** Run `jj status`. jj snapshots a workspace only when a jj
   command runs inside it; bytes the test suite or the user wrote since the
   last one are otherwise unreachable from the main checkout and destroyed by
   cleanup.
2. **Record before moving.** After the exit, `@` means the main checkout's
   working copy, so everything later steps need is captured now as values,
   not as `@`-relative revsets:
   ```bash
   jj log -r <target> --no-graph -T 'change_id.short()'   # <target-change-id>
   jj workspace root                                       # <left-workspace-root>
   jj workspace list --no-pager -T 'if(self.target().current_working_copy(), self.name() ++ "\n", "")'   # <left-workspace-name>
   ```
   The name comes from jj directly, not from matching roots against the
   Context list — `self.root()` renders empty for moved or pre-0.38.0
   workspaces, which is why the session briefing stopped matching on it.
3. **Exit.** Call `ExitWorktree` with `action: "keep"`. Never the removing
   form: it demands the discard flag for a jj workspace and is the path on
   which an agent lost work in anthropics/claude-code#85118. The change must
   be pushed and verified before anything is retired, and retirement is
   Step 5's job.
   Do not print the line below until the tool has confirmed. Then say:

   > This session is worktree-isolated and the harness refuses every remote
   > jj command here. Left the worktree (kept on disk at
   > `<left-workspace-root>`); finishing from the main checkout.

   Then record the main checkout's root — `<main-root>`:
   ```bash
   jj workspace root
   ```
4. **If ExitWorktree reports no active worktree session** (a resumed
   session, or any error), do not claim the exit happened. Run every step the
   guard permits yourself (the ancestor check, `jj bookmark create`,
   `jj abandon`, `jj op log`). Hand back only the refused commands, one `! `
   line per command, in order, with `<target-change-id>` substituted:
   - Option 1: `jj git push --bookmark <name>`, then the `gh pr create`
     heredoc (a compound command — also refused).
   - Option 2: `jj git fetch`; continue with its steps 2–5 once the user
     reports it ran.
   - Option 4: `jj git push --deleted`, only if the user asked for the remote
     branch to go.
   Skip Step 5. The workspace stays registered at `<left-workspace-root>`
   with its directory intact, so `/clean_stale` will **not** retire it (it
   forgets only rows whose directory is gone); tell the user to run
   `jj workspace forget <left-workspace-name>` once the handed-back commands
   have run. This is the only path on which `/finish` hands back.
5. **Continue with the option's steps.** Use `<target-change-id>` wherever
   the prose says `<target>` or `TARGET`; the one deliberate **commit**-id
   capture in Option 1 step 6 stands. State, rather than hide, what running
   from main changes: Option 1 step 6d's `jj new trunk()` re-points the
   **main checkout's** working copy, which is the intended end state for a
   finished thread — jj abandons main's previous `@` only if it was empty and
   undescribed; parked non-empty work stays as its own change, report it.
   Option 2 moves nothing: main's `@` is untouched, and the end state is the
   target rebased onto trunk with the trunk bookmark moved. Option 4's
   restore point is captured in its own step 1, from main — valid, because
   step 1 above already snapshotted the workspace's bytes as a prior
   operation.
6. **If a remote command fails after the exit**, report the failure and
   `<target-change-id>`, and stop. Nothing is lost: the workspace is intact at
   `<left-workspace-root>` and still registered, and the change is reachable
   by its id from anywhere. Re-entering by path is not possible
   (`EnterWorktree` requires `git worktree list`); the user can `cd` into the
   directory and run plain `claude` there, which is unguarded.

````

- [ ] **Step 3: Lead-in under Step 4, and the `TARGET` tokens**

Immediately **after** the line `## Step 4: Execute choice`, insert:

```markdown
If any command in this step is refused with *"This session is isolated in the
worktree ..."*, Step 3.5 was skipped — return to it before retrying.

```

In Option 1 step 1, replace the revset line:

```bash
   jj log -r 'ancestors(TARGET) & ~ancestors(trunk()) & ~TARGET' --no-graph
```

with:

```bash
   jj log -r 'ancestors(<target>) & ~ancestors(trunk()) & ~<target>' --no-graph
```

- [ ] **Step 4: Option 4 edits — restore point, pushed check, recovery**

Option 4 step 1: after the paragraph ending `which is exactly the work about to be discarded.`, add:

```markdown
   If Step 3.5 ran, you are in the main checkout now. This id still covers
   the workspace's bytes: Step 3.5's `jj status` snapshotted them as a prior
   operation. Capture it here, once — not in Step 3.5.
```

Option 4 step 2, replace:

```markdown
2. **State what is going, and whether a copy survives anywhere.** Read the
   target's bookmarks from Context — do not assert either line below without
   having looked:
```

with:

```markdown
2. **State what is going, and whether a copy survives anywhere.** Read the
   target's bookmarks with `jj bookmark list -r <target> --all-remotes` — a
   `@origin` row (any `@<remote>` other than `@git`) means pushed. Context's
   bookmark line is about `@`, not the target, and `jj git remote list` is
   refused in an isolated workspace. Do not assert either line below without
   having looked:
```

Option 4 step 4: after the second recovery block (the one ending `then re-publish:     jj git push --bookmark <name>` and its closing fence), add:

```markdown
   **If Step 5.0 retires a left workspace**, `jj op restore` also brings back
   that workspace's registration — its directory is gone by then, so the row
   is permanently stale. Add to the recovery line:
   ```
   then: jj workspace forget <left-workspace-name>
   ```
```

- [ ] **Step 5: Run the prose-claims suite; five of six pass**

Run: `bash plugins/commit-commands-jj/tests/test-command-prose-claims.sh`
Expected: `ok` for the heading order, `names ExitWorktree`, `holds no executable 'jj git'`, `exits with keep`, `states that the option choice is the user's ask`; `FAIL - finish.md never-remove exception is missing ...`. Exit 1.

- [ ] **Step 6: Record the change**

```bash
jj describe -m "feat(commit-commands-jj): /finish Step 3.5 leaves a harness worktree (ExitWorktree keep) before any remote command"
jj new
```

### Task 8 (B3): `/finish` Step 5 cleanup of the left workspace, rules, README

**Files:**
- Modify: `plugins/commit-commands-jj/commands/finish.md` — Step 5 (`## Step 5: Workspace cleanup` through `## Quick Reference`), Important Rules bullet `Don't auto-remove worktree directories`
- Modify: `plugins/commit-commands-jj/README.md` (the `/finish` bullets)

**Interfaces:**
- Consumes: Task B2's recorded values; Part A's `.claude/hooks/jj-workspace-remove.sh <worktree_path> <cwd>`.
- Produces: the `left in Step 3.5` exception text in both rule sites (Task B1 assertion 6).

- [ ] **Step 1: Rewrite Step 5**

Replace the whole `## Step 5: Workspace cleanup` section (up to but not including `## Quick Reference`) with:

````markdown
## Step 5: Workspace cleanup

**For Options 1, 2, and 4 only.**

0. **If Step 3.5 left a workspace, retire that one and stop.** After the
   exit the current workspace *is* `default`, so the check in 1 below would
   wrongly conclude there is nothing to do. The WorktreeRemove hook cannot
   fire for a worktree the session has already left, so `/finish` retires it
   through the same script the hook runs, with positional arguments. Run it
   from `<main-root>` — ExitWorktree returns the session to the directory it
   was launched from, which for `claude --worktree` at the repo root is
   `<main-root>`; check `pwd` first. If they differ, run the script by its
   absolute path `<main-root>/.claude/hooks/jj-workspace-remove.sh ...`,
   which sits outside the pre-approved pattern: expect one permission prompt
   and say so.
   ```bash
   .claude/hooks/jj-workspace-remove.sh <left-workspace-root> <main-root>
   ```
   Run this whether or not the user accepted Option 4's remote deletion. The
   script prints nothing on success, so confirm rather than assume:
   ```bash
   jj workspace list --no-pager -T 'self.name() ++ "\n"'
   ```
   `<left-workspace-name>` must be gone. If the script does not exist (a
   repo that never ran `/project-setup`), forget the workspace yourself and
   hand the directory back — `/finish` never runs `rm`:
   ```bash
   jj workspace forget <left-workspace-name>
   ```
   ```
   Workspace <left-workspace-name> forgotten. Remove its directory by hand:
   rm -rf <left-workspace-root>
   ```
   Report what ran. Stop here.

1. **Identify the current workspace by root, not by name.** Read the two
   workspace lines from Context: the current workspace is the row of the
   list whose root equals the current workspace root. (The list template is
   pinned deliberately — jj 0.44 changed what `jj workspace list` prints by
   default, and this step depends on the root field being present.) On macOS,
   `/tmp` is a symlink to `/private/tmp` — treat the two spellings of a path
   as the same location when matching.

   If the current workspace is `default`, no cleanup is needed. Stop here.

2. **Branch on provenance — who created the workspace decides who ends it:**

   - **Root under `/tmp/jj-workspaces/`** — an ephemeral workspace the
     WorktreeCreate hook made. Reached only if Step 3.5 did not run (it
     leaves the worktree for every option that gets here). Ours to clean up:
     ```bash
     jj workspace forget <workspace-name>
     ```
     jj warns *the current workspace no longer exists after this operation*
     and leaves the directory with no working copy — say so, and run nothing
     further with jj from this directory.
   - **Any other root** — a durable side thread (e.g. a `jjtab` sibling
     directory). Ending one with `/finish` is a documented use, but the thread
     outlives any single change, so ending it is the user's call, not a side
     effect — ask:
     ```
     This session is in the durable workspace <name> (<root>).
     Finish the side thread too (forget the workspace), or keep it for more work?
     ```
     Forget only on a yes. Keeping it is not a failure — report the change as
     finished and the workspace as kept.

3. **Report what was cleaned up.** Never remove the workspace directory
   itself — the WorktreeRemove hook owns ephemeral directories, and a durable
   directory's removal is the user's to do by hand. The one exception is an
   ephemeral workspace this session **left in Step 3.5**: the hook can no
   longer fire for it, so step 0 retires it through the hook's own script.

````

- [ ] **Step 2: Amend the Important Rules bullet**

Replace:

```markdown
- **Don't auto-remove worktree directories.** Let the WorktreeRemove hook handle it.
```

with:

```markdown
- **Don't auto-remove worktree directories.** Let the WorktreeRemove hook handle it. The one exception is an ephemeral workspace this session **left in Step 3.5** (ExitWorktree keep, because the harness refuses `jj git` inside it): the hook cannot fire for it any more, so Step 5.0 runs the hook's own script, `.claude/hooks/jj-workspace-remove.sh <root> <main-root>`, which refuses any path outside `/tmp/jj-workspaces/`. `/finish` itself never runs `rm`.
```

- [ ] **Step 3: Update the README bullets**

In `plugins/commit-commands-jj/README.md`, replace item 5 of "What it does":

```markdown
5. For push, merge, and discard, cleans up the jj workspace if running in a non-default one (`jj workspace forget`) — auto-forgetting only ephemeral hook-created workspaces, and asking before ending a durable side thread
```

with:

```markdown
5. In a harness-isolated workspace (one the WorktreeCreate hook made for `claude --worktree` / `EnterWorktree`, where Claude Code refuses every `jj git` command), leaves the worktree with `ExitWorktree` keep *before* the first remote command and finishes from the main checkout — your option choice is the ask
6. For push, merge, and discard, cleans up the jj workspace if running in a non-default one (`jj workspace forget`) — auto-forgetting only ephemeral hook-created workspaces (retiring a left one through the WorktreeRemove hook's script), and asking before ending a durable side thread
```

and replace the Features bullet:

```markdown
- Workspace cleanup respects provenance — auto-forgets only ephemeral hook-created workspaces (`/tmp/jj-workspaces/`), and asks before ending a durable side thread
```

with:

```markdown
- Workspace cleanup respects provenance — auto-forgets only ephemeral hook-created workspaces (`/tmp/jj-workspaces/`), and asks before ending a durable side thread
- Finishes unattended from a session that started with `claude --worktree`: leaves the harness worktree before pushing instead of handing every `jj git` command back to you. For work that will push, `jjtab` (workspace-jj README) remains the recommended door — it has no guard at all
```

- [ ] **Step 4: Run the prose-claims suite; all green**

Run: `bash plugins/commit-commands-jj/tests/test-command-prose-claims.sh`
Expected: every assertion `ok`, exit 0.

- [ ] **Step 5: Record the change**

```bash
jj describe -m "feat(commit-commands-jj): /finish Step 5 retires a left workspace via the remove hook; rules + README"
jj new
```

### Task 9 (B4): Version bump, full suite, PR

**Files:**
- Modify: `plugins/commit-commands-jj/.claude-plugin/plugin.json:4`

- [ ] **Step 1: Bump the version**

```bash
sed -i 's/"version": "0.19.0"/"version": "0.20.0"/' plugins/commit-commands-jj/.claude-plugin/plugin.json
grep -n '"version"' plugins/commit-commands-jj/.claude-plugin/plugin.json
```

Expected: `4:  "version": "0.20.0",`

- [ ] **Step 2: Run every suite**

Run the "Run all suites" loop. Expected: every line `PASS`.

- [ ] **Step 3: Record and open the PR**

```bash
jj describe -m "chore(commit-commands-jj): 0.20.0 — /finish leaves a harness worktree before its remote phase"
```

Run `/finish`, option 1. Title: `feat(commit-commands-jj): /finish leaves a harness-isolated worktree before pushing (Step 3.5)`. PR body: the Task B0 dry-run results, and the dependency note — Step 5.0's positional call needs project-setup-jj 0.20.0 hooks installed in the project (`/project-setup` re-run); until then the forget-and-hand-back fallback runs.

---

## Part C — workspace-jj 0.5.0

**Precondition:** PR 2 merged (the README names `/finish`'s new behaviour). Then:
```bash
jj git fetch
jj new 'trunk()' -m "docs(workspace-jj): route PR work to jjtab; document the isolation guard"
```

### Task 10 (C1): READMEs reroute, hook description, `jjtab`, version bump, PR

**Files:**
- Modify: `plugins/workspace-jj/README.md` — lines 11–14 (How It Works, through the `Workspaces share the same repository store` paragraph), the Usage block, the Side Threads table and the `jjtab` block
- Modify: `README.md` (repo root) — the workspace-jj Setup block's step 3
- Modify: `plugins/workspace-jj/.claude-plugin/plugin.json:4`

- [ ] **Step 1: Rewrite "How It Works"**

Replace lines 11–14 of `plugins/workspace-jj/README.md` — from `- **WorktreeCreate**: Runs \`jj workspace add --revision @-\`` through the paragraph `Workspaces share the same repository store (lightweight, fast to create) but each gets an independent working copy pinned to the same parent revision.` — with:

```markdown
- **WorktreeCreate**: Runs `jj workspace add --revision <trunk>` to create an isolated workspace at `/tmp/jj-workspaces/<project>/<name>/`, based on `trunk()` (falling back to `@-` in a repo with no remote, where `trunk()` would be the root commit). Workspaces are created outside the repo to prevent jj's auto-snapshotting from attributing workspace edits to the default workspace's `@`.
- **WorktreeRemove**: Runs `jj workspace forget` and removes the directory on cleanup. `/finish` calls the same script itself for a worktree the session has already left.

Workspaces share the same repository store (lightweight, fast to create) but each gets an independent working copy on the same base.

**A session in a hook-made workspace is harness-isolated.** Claude Code refuses every `jj git` command there (push, fetch, even `remote list`) and most compound shell commands: it reads the `git` token as a git invocation and cannot be configured otherwise. The SessionStart briefing says so at minute zero; `/finish` (commit-commands-jj 0.20+) leaves the worktree with `ExitWorktree` keep before its first remote command. The briefing fires only at session start, so a mid-session `EnterWorktree` gets no notice — `/finish` still covers it. A workspace you make by hand (`jjtab` below) has no guard at all.
```

- [ ] **Step 2: Rewrite Usage**

Replace the Usage code block:

```bash
# Start Claude in an isolated jj workspace
claude --worktree feature-auth

# Auto-generated name
claude --worktree

# List all workspaces
/workspace-list
```

with:

```bash
# A thread that will end in a PR: hand-made workspace, plain claude, no guard
jjtab feature-auth            # shell function below

# A read-only spike: harness worktree (guarded — no jj git inside)
claude --worktree spike-auth

# List all workspaces
/workspace-list
```

- [ ] **Step 3: Rewrite the door table and `jjtab`**

Replace the table under `## Side Threads: Which Door to Use` with:

```markdown
The harness guard (above) decides the door: anything that will push starts in a workspace the harness did not create.

| Situation | Use | Guard |
|-----------|-----|-------|
| New tab, anything that ends in a PR | `jjtab <name> [revset]` (below) | none |
| New tab, read-only spike | `claude --worktree <name>` — the WorktreeCreate hook makes the workspace | yes |
| Already in a session, read-only spike | ask Claude to enter a worktree (native `EnterWorktree` → same hook; it cannot enter a `jjtab` workspace) | yes |
| In a guarded workspace and need to push | `/finish` leaves the worktree for you (commit-commands-jj 0.20+); otherwise `ExitWorktree` with keep, then push from the main checkout — bookmarks and changes are repo-global | lifted |
| Parallel agent execution of a plan | `/kaisen` — the skill manages workspaces itself | none |

`jjtab` is a terminal door only: it ends by launching `claude`, so Claude cannot route itself there mid-session — which is why `/finish` handles the guarded case.
```

Replace the `jjtab` function block (from `The \`jjtab\` function for your shell config:` through the closing fence) with:

````markdown
The `jjtab` function for your shell config:

```bash
# jjtab NAME [REVSET] — durable jj workspace beside the repo + plain claude in it.
#   - base is trunk(), never `@-`: a thread must not inherit a parked empty change.
#   - dir is <repo>-ws/NAME, a sibling of the repo; survives reboots.
# Plain `claude`, NOT `claude --worktree`: the harness worktree-isolation guard
# refuses every `jj git push/fetch` form and cannot be configured off, so a
# thread that must push needs a workspace the harness did not create.
# Run from the MAIN checkout: `jj root` is the current workspace's root, so
# running inside <repo>-ws/<x> would nest <x>-ws under it (guarded below).
# Finish with /finish in-session, or `jj workspace forget NAME` + rm the dir.
jjtab() {
  local name=${1:?usage: jjtab NAME [REVSET]}
  local rev=${2:-'trunk()'}
  local root
  root=$(jj root) || return
  case "$(dirname "$root")" in
    *-ws) echo "jjtab: run from the main checkout, not a workspace ($root)" >&2; return 1 ;;
  esac
  local dir="${root}-ws/$name"
  mkdir -p "$(dirname "$dir")" || return   # jj workspace add needs the parent to exist
  jj workspace add "$dir" --name "$name" --revision "$rev" || return
  cd "$dir" && claude
}
```
````

Leave the divergent-change paragraph, the "Finish a side thread" line, Requirements, Cleanup and the Kaisen section as they are.

- [ ] **Step 4: Root README setup step**

In the repo root `README.md`, replace:

```bash
# 3. Restart Claude Code, then use worktrees
claude --worktree feature-auth
```

with:

```bash
# 3. Restart Claude Code, then start a thread
jjtab feature-auth          # work that will push: hand-made workspace, plain claude (see the plugin README)
claude --worktree spike     # read-only spike: harness worktree — `jj git` is refused inside it
```

- [ ] **Step 5: Bump the version and lint**

```bash
sed -i 's/"version": "0.4.0"/"version": "0.5.0"/' plugins/workspace-jj/.claude-plugin/plugin.json
grep -n '"version"' plugins/workspace-jj/.claude-plugin/plugin.json
bash .github/tests/test-readme-no-version.sh
grep -rn -- '--revision @-' plugins/ README.md || echo "no stale @- pin left"
```

Expected: `4:  "version": "0.5.0",`; the README lint passes (it keys on a `## Version` heading, which this README does not add; the inline "0.20+" is allowed); `no stale @- pin left`.

- [ ] **Step 6: Run every suite, record, open the PR**

Run the "Run all suites" loop. Expected: every line `PASS`.

```bash
jj describe -m "docs(workspace-jj): 0.5.0 — route PR work to jjtab, document the harness isolation guard, trunk()-based hook"
```

Run `/finish`, option 1. Title: `docs(workspace-jj): route PR threads to jjtab; document the worktree isolation guard`.

---

## After all three PRs merge

- In tokotoko (and any other project on these plugins): update the plugins, then run `/project-setup` so the installed `.claude/hooks/` copies pick up the new create/remove/session-start scripts. Three layers go stale independently (source → cache → installed copy); the cache is keyed by version, which is why every part bumps.
- Update the `jjtab` function in `~/.zshrc` with the `mkdir -p` line from Task C1 — the copy there has the same missing-parent failure for a first `<repo>-ws/` directory.
- In-session acceptance check (spec "Testing", last bullet): `claude --worktree` in this repo → the briefing shows `== Worktree isolation ==`; make a trivial change; `/finish` option 1 runs end to end with no `! jj git` handoff and `jj workspace list` shows only `default` afterwards.
- Optional follow-up outside this plan: comment on anthropics/claude-code#85118 with the refused `jj git` forms from the spec's Background.
