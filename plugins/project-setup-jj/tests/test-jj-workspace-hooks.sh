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
