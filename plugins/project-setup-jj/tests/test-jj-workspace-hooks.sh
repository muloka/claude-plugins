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
cleanup() { rm -rf "$TMPROOT" "/tmp/jj-workspaces/$UNIQ" "/tmp/jj-workspaces-evil-$UNIQ"; }
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

# Arm 3: fresh repo, no remote, no parked change — @- IS the root commit
# (only `@` with files, parent = root). The tier-2 fallback (`@- ~ root()`)
# must carry the same guard tier 1 does, or it silently produces the same
# empty workspace an unguarded `trunk()` would; expect the fallthrough to
# tier 3 (no --revision), files present, parent not the root commit.
root2b=$(new_repo)
seed_repo "$root2b"
ws2b=$(HOOK "$root2b" "$CREATE" "{\"name\":\"freshroot\",\"cwd\":\"$root2b/$UNIQ\"}" 2>/dev/null)
if [ -f "$ws2b/README.md" ]; then
  ok "fresh repo (@- is root): workspace contains the repo's files"
else
  bad "fresh repo (@- is root): README.md missing from the workspace"
fi
ws2b_parent=$(R "$root2b" jj -R "$ws2b" log -r '@-' --no-graph -T 'commit_id' 2>/dev/null)
if [ -n "$ws2b_parent" ] && ! printf '%s' "$ws2b_parent" | grep -qE '^0+$'; then
  ok "fresh repo (@- is root): workspace parent is not the root commit"
else
  bad "fresh repo (@- is root): workspace parent is '$ws2b_parent' (root commit or empty — tier-2 guard failed)"
fi
HOOK "$root2b" "$REMOVE" "{\"worktree_path\":\"$ws2b\",\"cwd\":\"$root2b/$UNIQ\"}" >/dev/null 2>&1

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

# '..' traversal: the prefix guard is lexical (a case pattern match on the
# string, not a resolved path), so a crafted path that lexically starts with
# /tmp/jj-workspaces/<repo>/ but RESOLVES elsewhere (via the '..' segments
# `rm -rf` itself will follow) must be refused before it ever reaches rm.
victim="$root3/$UNIQ/victim"
mkdir -p "$victim"
crafted="/tmp/jj-workspaces/$UNIQ/x/../../../..$victim"
R "$root3" bash "$REMOVE" "$crafted" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "'..' traversal: refused with exit 2"
else
  bad "'..' traversal: expected exit 2, got $rc"
fi
if [ -d "$victim" ]; then
  ok "'..' traversal: victim directory untouched"
else
  bad "'..' traversal: victim directory was removed"
fi

# Near-miss prefix: a directory that merely starts with the same characters as
# /tmp/jj-workspaces (but is a different directory name) must not satisfy the
# guard. Cleaned up by the top-level trap.
evil="/tmp/jj-workspaces-evil-$UNIQ/a/b"
mkdir -p "$evil"
R "$root3" bash "$REMOVE" "$evil" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "near-miss prefix: refused with exit 2"
else
  bad "near-miss prefix: expected exit 2, got $rc"
fi
if [ -d "$evil" ]; then
  ok "near-miss prefix: directory untouched"
else
  bad "near-miss prefix: directory was removed"
fi

# One-segment path: the repo directory itself (/tmp/jj-workspaces/<repo>, with
# no <name> tail) exists because earlier cases created workspaces under it,
# and must be refused rather than treated as a valid workspace path.
R "$root3" bash "$REMOVE" "/tmp/jj-workspaces/$UNIQ" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "one-segment path: refused with exit 2"
else
  bad "one-segment path: expected exit 2, got $rc"
fi
if [ -d "/tmp/jj-workspaces/$UNIQ" ]; then
  ok "one-segment path: repo directory untouched"
else
  bad "one-segment path: repo directory was removed"
fi

# Double trailing slash: the strip must be a loop, not a single '%/' removal.
wsds=$(HOOK "$root3" "$CREATE" "{\"name\":\"dslash\",\"cwd\":\"$root3/$UNIQ\"}" 2>/dev/null)
R "$root3" bash "$REMOVE" "$wsds//" "$root3/$UNIQ" >/dev/null 2>&1 </dev/null
if R "$root3" jj workspace list 2>/dev/null | grep -q '^workspace-dslash:'; then
  bad "double trailing slash: workspace-dslash still registered"
else
  ok "double trailing slash: workspace forgotten"
fi
if [ -e "$wsds" ]; then
  bad "double trailing slash: directory still exists: $wsds"
else
  ok "double trailing slash: directory removed"
fi

# One-argument call must not silently fall into the stdin branch.
R "$root3" bash "$REMOVE" "onlyonearg" >/dev/null 2>&1 </dev/null
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "one-argument call: refused with exit 2"
else
  bad "one-argument call: expected exit 2, got $rc"
fi

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
