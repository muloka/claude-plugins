#!/usr/bin/env bash
# The jj behaviours this plugin's command prose ASSERTS must still be true.
#
# Same principle as .github/tests/test-jj-recommendations.sh, one level up:
# that suite checks the raw-git wall never recommends a command jj removed;
# this one checks the commands never *describe* behaviour jj no longer has.
# Prose rots silently — the command still reads authoritatively while telling
# the model something false, and nothing surfaces it until a user is misled.
#
# Every claim below was measured on jj 0.43.0 during #104. Two of them were
# wrong at the time of writing and are pinned so they cannot drift back
# unnoticed; the rest guard against jj changing under correct prose.
#
# bash 3.2 safe: no globstar, no associative arrays.
set -uo pipefail

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jj >/dev/null 2>&1; then
  printf 'FAIL - jj must be installed to verify prose claims\n'
  printf '0 passed, 1 failed\n'
  exit 1
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# A throwaway repo with a real file:// remote, run under a sandbox HOME so the
# developer's own ~/.config/jj is never read or written (#118).
new_repo() {
  nr_root=$(mktemp -d "$TMPROOT/r.XXXXXX")
  mkdir -p "$nr_root/home/.config/jj" "$nr_root/cwd"
  printf '[user]\nname = "test"\nemail = "test@example.com"\n\n[ui]\npaginate = "never"\neditor = "true"\n' \
    > "$nr_root/home/.config/jj/config.toml"
  printf '%s\n' "$nr_root"
}

R() { r_root="$1"; shift; ( cd "$r_root/cwd" && env -i PATH="$PATH" \
    HOME="$r_root/home" USERPROFILE="$r_root/home" \
    XDG_CONFIG_HOME="$r_root/home/.config" TMPDIR="${TMPDIR:-/tmp}" \
    TERM=dumb "$@" ); }

# --- clean_stale.md — "There is no --prune flag because there is nothing to opt
# into". No line number: the claim has already moved once (it was :25), and a
# stale pointer in a failure message costs more than it saves.
if jj git fetch --help 2>&1 | grep -q -- '--prune'; then
  bad "clean_stale.md says no --prune is needed, but jj git fetch now HAS --prune"
else
  ok "jj git fetch has no --prune flag (clean_stale.md is accurate)"
fi

# --- No command may recommend `jj git push --allow-new`; it was removed.
if jj git push --help 2>&1 | grep -q -- '--allow-new'; then
  bad "jj git push --allow-new exists again — check whether any command should mention it"
else
  ok "jj git push has no --allow-new flag"
fi
if grep -rn -- '--allow-new' "$(cd "$(dirname "$0")/.." && pwd)/commands" 2>/dev/null | grep -q .; then
  bad "a command file recommends --allow-new, which jj removed"
else
  ok "no command file recommends the removed --allow-new flag"
fi

# --- clean_stale.md steps 2 and 4 are VESTIGIAL (#132): `jj git fetch` already
# removes a local bookmark whose remote branch was deleted, so there is nothing
# left for "find stale bookmarks, then jj bookmark delete" to do. If this ever
# fails, jj changed and that prose becomes correct again — reopen #132.
root=$(new_repo)
R "$root" jj git init . >/dev/null 2>&1
printf 'origin.git/\n' > "$root/cwd/.gitignore"
R "$root" git init --bare --quiet origin.git
R "$root" jj git remote add origin "$root/cwd/origin.git" >/dev/null 2>&1
printf 'hello\n' > "$root/cwd/README.md"
R "$root" jj describe -m "Initial commit" >/dev/null 2>&1
R "$root" jj bookmark create main -r @ >/dev/null 2>&1
R "$root" jj git push --bookmark main >/dev/null 2>&1
R "$root" jj new main >/dev/null 2>&1
printf 'merged\n' > "$root/cwd/merged.txt"
R "$root" jj describe -m "Merged feature" >/dev/null 2>&1
R "$root" jj bookmark create feature-gone -r @ >/dev/null 2>&1
R "$root" jj git push --bookmark feature-gone >/dev/null 2>&1
R "$root" jj new main >/dev/null 2>&1
# Delete the branch on the remote, as a merge-and-delete upstream would.
R "$root" git --git-dir=origin.git update-ref -d refs/heads/feature-gone >/dev/null 2>&1
R "$root" jj git fetch >/dev/null 2>&1
if R "$root" jj bookmark list 2>&1 | grep -q '^feature-gone'; then
  bad "jj git fetch no longer auto-removes a stale bookmark — clean_stale.md steps 2/4 are live again (#132)"
else
  ok "jj git fetch auto-removes a stale tracked bookmark (clean_stale.md steps 2/4 remain vestigial, #132)"
fi

# --- ...and the prose must keep saying so (#132). The assertion above proves jj
# does the work; this one proves clean_stale.md has not grown the redundant step
# back. Only *executable* instructions count — the file legitimately names
# `jj bookmark delete` in prose to warn the model off it, so this looks solely
# inside fenced code blocks.
CMDS="$(cd "$(dirname "$0")/.." && pwd)/commands"
fenced() { awk '/^[[:space:]]*```/{inb=!inb; next} inb' "$1"; }
if fenced "$CMDS/clean_stale.md" | grep -q 'jj bookmark delete'; then
  bad "clean_stale.md executes 'jj bookmark delete' again — jj git fetch already removed it (#132)"
else
  ok "clean_stale.md prescribes no redundant 'jj bookmark delete' (#132)"
fi

# --- finish.md Option 4 (#135). The gate that demanded a typed 'discard' fired
# 2 of 13 measured runs; the prose now promises the thing that fired 3/3 —
# capture an op id, abandon, hand back `jj op restore <id>`. Two claims ride on
# that, and both are asserted here:
#
#   default   an id captured with `jj op log -n 1 --no-graph -T 'id.short()'`
#             restores the abandoned change, INCLUDING an edit jj had not yet
#             snapshotted (op log snapshots before it reports).
#   ignore-wc adding --ignore-working-copy skips that snapshot and yields a
#             restore point predating the last edits — the trap the prose warns
#             about.
#
# Run as a two-arm comparison on purpose: a lone "restore works" check would
# still pass if the flag stopped mattering, and finish.md's warning would rot
# unnoticed. Arms must disagree.
for mode in default ignore-wc; do
  fr=$(new_repo)
  R "$fr" jj git init . >/dev/null 2>&1
  printf 'base\n' > "$fr/cwd/README.md"
  R "$fr" jj describe -m "Initial commit" >/dev/null 2>&1
  R "$fr" jj bookmark create main -r @ >/dev/null 2>&1
  R "$fr" jj new main >/dev/null 2>&1
  R "$fr" jj describe -m "Experimental spike" >/dev/null 2>&1
  R "$fr" jj log -r @ >/dev/null 2>&1          # settle the op log...
  printf 'late\n' > "$fr/cwd/late.txt"         # ...then edit, unsnapshotted

  if [ "$mode" = ignore-wc ]; then
    cp_id=$(R "$fr" jj op log -n 1 --no-graph --ignore-working-copy -T 'id.short()')
  else
    cp_id=$(R "$fr" jj op log -n 1 --no-graph -T 'id.short()')
  fi

  if [ -z "$cp_id" ]; then
    bad "jj op log -n 1 --no-graph -T 'id.short()' rendered nothing — finish.md Option 4 step 1 is broken ($mode)"
    continue
  fi

  tgt=$(R "$fr" jj log -r @ --no-graph --ignore-working-copy -T 'change_id.short()')
  R "$fr" jj abandon "$tgt" >/dev/null 2>&1
  R "$fr" jj op restore "$cp_id" >/dev/null 2>&1

  if [ "$mode" = default ]; then
    if [ -e "$fr/cwd/late.txt" ]; then
      ok "jj op restore recovers an abandoned change incl. unsnapshotted edits (finish.md Option 4)"
    else
      bad "jj op restore did NOT recover the abandoned work — finish.md Option 4 promises it does (#135)"
    fi
  else
    if [ -e "$fr/cwd/late.txt" ]; then
      bad "--ignore-working-copy no longer costs the latest edits — finish.md's step-1 warning is now wrong (#135)"
    else
      ok "capturing with --ignore-working-copy loses the latest edits (finish.md's warning holds)"
    fi
  fi
done

# --- `jj git init` COLOCATES BY DEFAULT on 0.43. Any future eval scaffold or
# tooling that relies on git being unusable in the work tree must pass
# --no-colocate; a plain init does NOT hide the git dir. Pinned because a
# scaffold once claimed non-colocation it did not have, and the measured
# consequence was a model doing a jj task entirely in raw git.
c1=$(new_repo); R "$c1" jj git init . >/dev/null 2>&1
c2=$(new_repo); R "$c2" jj git init . --no-colocate >/dev/null 2>&1
dg="$(printf '.')git"
if [ -e "$c1/cwd/$dg" ]; then
  ok "plain 'jj git init' colocates (so isolation requires --no-colocate)"
else
  ok "plain 'jj git init' no longer colocates — the default flipped; --no-colocate is now redundant"
fi
if [ -e "$c2/cwd/$dg" ]; then
  bad "--no-colocate did not prevent colocation"
else
  ok "'jj git init --no-colocate' produces a non-colocated repo"
fi

# --- finish.md Option 4, PUSHED case. Measured 2026-08-01: given a pushed
# spike and "get rid of this work", 3 of 3 agents abandoned locally AND pushed
# the bookmark deletion, destroying the remote's copy — then offered a bare
# `jj op restore <id>` as the recovery path. That bare form is WRONG here: it
# restores remote-tracking refs as well, so jj believes the remote still holds
# the bookmark and the next push answers "Nothing changed." over an empty
# remote. Silent loss behind a success message. `--what repo` is the fix, and
# jj's own help says so ("Do not restore these if you'd like to push after the
# undo").
#
# Two arms, because the whole point is that they differ: if a future jj made
# the bare form safe, a one-armed check would keep passing and the prose would
# rot in the harmful direction.
# The bare remote MUST live outside the work tree. With origin.git inside it,
# jj tracks the remote's own files as content and `jj op restore` restores the
# remote itself — both arms then "succeed" and the assertion silently inverts.
# Measured: that scaffold reports LANDED/LANDED, the correct one EMPTY/LANDED.
for mode in bare what-repo; do
  pr=$(new_repo)
  R "$pr" jj git init . --no-colocate >/dev/null 2>&1
  ( cd "$pr" && env -i PATH="$PATH" HOME="$pr/home" TERM=dumb git init --bare --quiet origin.git )
  R "$pr" jj git remote add origin "$pr/origin.git" >/dev/null 2>&1
  printf 'base\n' > "$pr/cwd/README.md"
  R "$pr" jj describe -m "Initial commit" >/dev/null 2>&1
  R "$pr" jj bookmark create main -r @ >/dev/null 2>&1
  R "$pr" jj git push --bookmark main >/dev/null 2>&1
  R "$pr" jj new main >/dev/null 2>&1
  printf 'spike\n' > "$pr/cwd/spike.txt"
  R "$pr" jj describe -m "Pushed spike" >/dev/null 2>&1
  R "$pr" jj bookmark create pushed-spike -r @ >/dev/null 2>&1
  R "$pr" jj git push --bookmark pushed-spike >/dev/null 2>&1

  op=$(R "$pr" jj op log -n 1 --no-graph -T 'id.short()')
  t=$(R "$pr" jj log -r @ --no-graph -T 'change_id.short()')
  R "$pr" jj abandon "$t" >/dev/null 2>&1
  R "$pr" jj git push --deleted >/dev/null 2>&1   # destroy the remote copy

  if [ "$mode" = what-repo ]; then
    R "$pr" jj op restore "$op" --what repo >/dev/null 2>&1
  else
    R "$pr" jj op restore "$op" >/dev/null 2>&1
  fi
  R "$pr" jj git push --bookmark pushed-spike >/dev/null 2>&1

  # Ground truth is the REMOTE, not jj's belief about it.
  if ( env -i PATH="$PATH" HOME="$pr/home" TERM=dumb \
       git --git-dir="$pr/origin.git" show-ref --quiet refs/heads/pushed-spike ); then
    landed=yes
  else
    landed=no
  fi

  if [ "$mode" = what-repo ]; then
    if [ "$landed" = yes ]; then
      ok "jj op restore --what repo lets a deleted pushed bookmark be re-pushed (finish.md Option 4)"
    else
      bad "jj op restore --what repo no longer restores a pushed bookmark — finish.md's recovery command is wrong (#135)"
    fi
  else
    if [ "$landed" = yes ]; then
      bad "a BARE jj op restore now re-publishes fine — finish.md's --what repo warning has become wrong (#135)"
    else
      ok "a bare jj op restore leaves the remote empty and the re-push a no-op (finish.md's warning holds)"
    fi
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
