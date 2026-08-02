#!/usr/bin/env bash
# Every jj invocation this plugin's commands contain must still be valid.
#
# Sibling to test-command-prose-claims.sh, and deliberately different in kind:
# that suite asserts BEHAVIOUR ("fetch already pruned the bookmark") by running
# jj; this one asserts the invocations EXIST — breadth, not depth.
#
# Why it exists (#142): prose rots silently. The file still reads
# authoritatively while naming a flag jj removed, and nothing surfaces it until
# a user is misled. `jj git push --allow-new` was reached for three separate
# times in this project by trusting recall; it does not exist in 0.43.0. Evals
# cannot catch this class — the model routes around a bad flag and still scores
# well.
#
# Two sources, because commands carry invocations in two places:
#
#   1. !-injected Context commands. These AUTO-EXECUTE on every invocation of
#      the command, so a bad flag breaks it immediately. They contain no
#      placeholders, so they are checked by RUNNING them — which also validates
#      the -T templates, something --help cannot see. 16 of 16 command files
#      have at least one.
#   2. Fenced code examples. These contain <placeholders> and cannot be run, so
#      their long flags are checked against `jj <sub> --help`.
#
# bash 3.2 safe: no globstar, no associative arrays, no mapfile. Counts are
# accumulated through a FILE, not a pipeline — `... | while` runs in a subshell
# and silently loses them (the #84 lint shipped that bug inside its own fix).
set -uo pipefail

CMDS="$(cd "$(dirname "$0")/.." && pwd)/commands"
PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

if ! command -v jj >/dev/null 2>&1; then
  printf 'FAIL - jj must be installed to verify command invocations\n'
  printf '0 passed, 1 failed\n'
  exit 1
fi

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------- seeded repo
# Sandbox HOME so the developer's own ~/.config/jj is never read or written
# (#118: a scaffold once truncated it). Non-colocated so nothing can silently
# fall back to git. A remote exists so trunk() resolves; @- , a bookmark, a tag
# and real file content exist so log/diff/show/tag have something to render.
R="$TMPROOT/repo"
mkdir -p "$R/home/.config/jj" "$R/cwd"
printf '[user]\nname = "test"\nemail = "test@example.com"\n\n[ui]\npaginate = "never"\neditor = "true"\n' \
  > "$R/home/.config/jj/config.toml"
J() { ( cd "$R/cwd" && env -i PATH="$PATH" HOME="$R/home" USERPROFILE="$R/home" \
        XDG_CONFIG_HOME="$R/home/.config" TMPDIR="${TMPDIR:-/tmp}" TERM=dumb "$@" ); }

( cd "$R" && env -i PATH="$PATH" HOME="$R/home" TERM=dumb git init --bare --quiet origin.git )
J jj git init . --no-colocate       >/dev/null 2>&1
J jj git remote add origin "$R/origin.git" >/dev/null 2>&1
printf 'base\n' > "$R/cwd/README.md"
J jj describe -m "Initial commit"   >/dev/null 2>&1
J jj bookmark create main -r @      >/dev/null 2>&1
J jj git push --bookmark main       >/dev/null 2>&1
J jj new main                       >/dev/null 2>&1
printf 'feature\n' >  "$R/cwd/feature.txt"
printf 'more\n'    >> "$R/cwd/README.md"
J jj describe -m "Add feature"      >/dev/null 2>&1
( cd "$R" && env -i PATH="$PATH" HOME="$R/home" TERM=dumb git --git-dir=origin.git tag v1.0 ) >/dev/null 2>&1
J jj git fetch                      >/dev/null 2>&1

if ! J jj status >/dev/null 2>&1; then
  bad "could not seed the throwaway repo — the checks below would be vacuous"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi

# ------------------------------------------------ 1. injected Context commands
# Distinct across all command files; each is run verbatim in the seeded repo.
grep -ohE '!`jj [^`]+`' "$CMDS"/*.md 2>/dev/null \
  | sed 's/^!`//;s/`$//' | sort -u > "$TMPROOT/injected"

inj_total=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  inj_total=$((inj_total+1))
  if out=$( cd "$R/cwd" && env -i PATH="$PATH" HOME="$R/home" USERPROFILE="$R/home" \
            XDG_CONFIG_HOME="$R/home/.config" TMPDIR="${TMPDIR:-/tmp}" TERM=dumb \
            /bin/sh -c "$cmd" 2>&1 ); then
    ok "Context command runs: $cmd"
  else
    bad "Context command FAILED: $cmd -- $(printf '%s' "$out" | head -1)"
  fi
done < "$TMPROOT/injected"

if [ "$inj_total" -eq 0 ]; then
  bad "no !-injected commands found — the extractor broke, so this half is vacuous"
fi

# ------------------------------------------------------ 2. fenced example flags
# Long flags only; short flags are ambiguous to attribute without a full parser.
# Write results to a file: the loop is fed by a pipeline, so counters set inside
# it would be lost in the subshell.
: > "$TMPROOT/fenced"
for f in "$CMDS"/*.md; do
  fname=$(basename "$f")
  awk '/^[[:space:]]*```/{i=!i;next} i' "$f" | grep -E '^[[:space:]]*jj ' | sed 's/^[[:space:]]*//' |
  while IFS= read -r line; do
    line=${line%%#*}                       # drop trailing comments
    # shellcheck disable=SC2086
    set -- $line
    shift                                   # drop "jj"
    [ $# -gt 0 ] || continue

    # Derive the subcommand split rather than hardcoding a list: prefer the
    # two-word form when jj actually accepts it.
    sub="$1"
    if [ $# -ge 2 ]; then
      case "$2" in
        -*) : ;;
        *) if jj "$1" "$2" --help >/dev/null 2>&1; then sub="$1 $2"; shift; fi ;;
      esac
    fi
    shift

    # shellcheck disable=SC2086
    if ! help=$(jj $sub --help 2>&1); then
      printf 'FAIL\t%s: `jj %s` is not a jj subcommand\n' "$fname" "$sub" >> "$TMPROOT/fenced"
      continue
    fi

    for tok in "$@"; do
      case "$tok" in
        --) break ;;
        --*)
          flag=${tok%%=*}
          if printf '%s' "$help" | grep -q -- "$flag"; then
            printf 'ok\t%s: jj %s accepts %s\n' "$fname" "$sub" "$flag" >> "$TMPROOT/fenced"
          else
            printf 'FAIL\t%s: jj %s does NOT accept %s\n' "$fname" "$sub" "$flag" >> "$TMPROOT/fenced"
          fi ;;
      esac
    done
  done
done

# `wc -l`, not `grep -c .`: on an empty file grep prints "0" AND exits 1, so a
# `|| printf 0` fallback concatenates to "00" and the -eq test below misfires —
# leaving this guard silently unable to fire. Caught by mutation testing.
fen_total=$(wc -l < "$TMPROOT/fenced" | tr -d ' ')
while IFS= read -r row; do
  [ -n "$row" ] || continue
  case "$row" in
    ok*)   ok   "$(printf '%s' "$row" | cut -f2-)" ;;
    FAIL*) bad  "$(printf '%s' "$row" | cut -f2-)" ;;
  esac
done < "$TMPROOT/fenced"

if [ "$fen_total" -eq 0 ]; then
  bad "no fenced jj invocations found — the extractor broke, so this half is vacuous"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
