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

# --- clean_stale.md:25 — "jj automatically prunes ... no --prune flag needed"
if jj git fetch --help 2>&1 | grep -q -- '--prune'; then
  bad "clean_stale.md:25 says no --prune is needed, but jj git fetch now HAS --prune"
else
  ok "jj git fetch has no --prune flag (clean_stale.md:25 is accurate)"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
