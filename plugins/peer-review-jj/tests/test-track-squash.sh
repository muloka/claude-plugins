#!/usr/bin/env bash
# /peer-review --track, run as the requesting skill writes it.
#
# --track duplicates the reviewed change, inserts an empty described parent
# ("review: <id>") under the duplicate, and squashes each file into that parent
# as its review comes back clean. The last clean file empties the duplicate, and
# a squash that empties a DESCRIBED source asks jj to combine the two
# descriptions — which opens an editor. In an agent session that is a hang until
# timeout; during a review of this plugin it opened a GUI editor on the user's
# desktop. Every all-clean review ends on exactly that squash.
#
# Both blocks are lifted out of SKILL.md and executed, so this checks the prose
# rather than a hand-written stand-in for it. The sandbox editor is `false`:
# any attempt to open one fails the squash instead of waiting on a human.
#
# bash 3.2 safe: no globstar, no associative arrays.
set -uo pipefail

SKILL="$(cd "$(dirname "$0")/.." && pwd)/skills/requesting-change-review/SKILL.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jj >/dev/null 2>&1; then
  printf 'FAIL - jj must be installed\n0 passed, 1 failed\n'; exit 1
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/home/.config/jj" "$TMPROOT/cwd"
printf '[user]\nname = "test"\nemail = "test@example.com"\n\n[ui]\npaginate = "never"\neditor = "false"\n' \
  > "$TMPROOT/home/.config/jj/config.toml"
R() { ( cd "$TMPROOT/cwd" && env -i PATH="$PATH" HOME="$TMPROOT/home" USERPROFILE="$TMPROOT/home" \
        XDG_CONFIG_HOME="$TMPROOT/home/.config" TMPDIR="${TMPDIR:-/tmp}" TERM=dumb "$@" ); }

# The fenced code under a heading (matched literally), up to the next heading.
# Fence state is tracked first, so a `# comment` inside a bash block is not
# mistaken for a heading.
block_after() {
  awk -v h="$1" '
    /^[[:space:]]*```/ { inb = !inb; if (f) print; next }
    !inb && /^#+ / { if (f) exit; if (index($0, h)) { f = 1; next } }
    f' "$SKILL" | awk '/^[[:space:]]*```/{inb=!inb; next} inb'
}

# A change under review, with two files.
R jj git init . --no-colocate >/dev/null 2>&1
printf 'one\n' > "$TMPROOT/cwd/one.txt"
printf 'two\n' > "$TMPROOT/cwd/two.txt"
R jj describe -m "feat: the change under review" >/dev/null 2>&1
target=$(R jj log -r @ --no-graph -T 'change_id.short(8)')
R jj new >/dev/null 2>&1

setup=$(block_after 'Setup (first run' | sed -e "s/<revision>/$target/g" -e "s/<change-id>/$target/g")
squash=$(block_after 'After Each Generalist Completes' | grep -E '^[[:space:]]*jj squash' | head -1 | sed 's/^[[:space:]]*//')
if [ -z "$setup" ] || [ -z "$squash" ]; then
  bad "SKILL.md: could not find the --track Setup block or the squash line"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi

# One shell for the whole flow: the squash names $REVIEWED_PARENT, set by setup.
run_review() {   # $1 = files the reviewer cleared, in order, one squash each
  script="set -e
$setup"
  for f in "$@"; do
    script="$script
$(printf '%s\n' "$squash" | sed "s|<files with no findings>|$f|")"
  done
  R bash -c "$script"
}

if run_review one.txt two.txt >"$TMPROOT/out" 2>&1; then
  ok "--track: squashing every clean file, the last one emptying the duplicate, needs no editor"
else
  bad "--track: the squash failed when it emptied the duplicate ($(grep -m1 -i 'error' "$TMPROOT/out"))"
fi

parent_desc=$(R jj log -r "description(substring:\"review: $target\")" --no-graph -T 'description.first_line()' 2>/dev/null)
parent_files=$(R jj file list -r "description(substring:\"review: $target\")" 2>/dev/null | sort | tr '\n' ' ')
if [ "$parent_desc" = "review: $target" ] && [ "$parent_files" = "one.txt two.txt " ]; then
  ok "--track: the reviewed parent keeps its 'review:' tag and holds every cleared file"
else
  bad "--track: reviewed parent is '$parent_desc' with [$parent_files]; want 'review: $target' with both files"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
