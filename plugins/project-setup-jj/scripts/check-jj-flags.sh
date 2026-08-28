#!/usr/bin/env bash
# PreToolUse hook: reject a jj flag that the INSTALLED jj does not have.
#
# WHY THIS EXISTS. `jj git push --allow-new` was correct for years and the flag
# is now gone — pushing a new bookmark is the default. The habit outlives the
# flag, and the failure costs a full round trip every time. This repo's own
# notes have recorded "--allow-new is gone, check --help, don't trust the rule"
# since three separate occurrences, and it was hit again anyway. A note that has
# to be remembered at the moment of typing is the wrong shape of fix; a hook
# fires whether or not anyone remembered.
#
# jj's own error is worse than nothing here:
#
#     error: unexpected argument '--allow-new' found
#       tip: a similar argument exists: '--all'
#
# `--all` pushes EVERY bookmark. Someone reaching for the old --allow-new wanted
# one new bookmark pushed, which is now just `--bookmark <name>`. Taking clap's
# suggestion turns a no-op flag into a repo-wide push. Answering precisely is
# most of this hook's value; the round trip saved is the rest.
#
# THE DECISION IS A PROPERTY, NOT A LIST. There is no table of removed flags
# here to fall out of date. The check asks the installed binary what it accepts
# (`jj git push --help`) and denies only what that binary does not list — so it
# is right across jj upgrades by construction, self-corrects if a flag returns,
# and needs no maintenance when the next one is dropped.
#
# WHERE THE LINE IS, and why it is drawn at `jj git push`.
#
# Like every hook of this kind the matcher is quote-blind: it cannot tell a flag
# from a mention of one. That is fatal for most jj subcommands, because their
# free-text arguments routinely contain flag names —
#
#     jj describe -m "fixture uses jj new --no-edit"
#
# — and a general version of this check would have denied several of this very
# repo's commit messages. So the check runs ONLY for subcommands whose every
# option takes a constrained value: a name, a revset, a remote. `jj git push` is
# the archetype and, today, the whole list: it has no message, no template, no
# free text anywhere in its surface, so a `--word` inside one is a flag or a
# typo and never prose.
#
# The subcommand scope below is therefore WHERE IT IS SAFE TO LOOK, not a list
# of what is wrong. Widening it is a claim about that subcommand's argument
# surface — that it takes no free text — and nothing else. Never widen it to one
# that accepts a message, a template, or a description.
#
# bash 3.2-safe: no globstar, no associative arrays. Deliberately no `set -e`:
# a hook that dies partway emits nothing, and silence here reads as approval.

input=$(cat)

command -v jj >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

command=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -n "$command" ] || exit 0

# Split into clauses on the same separators block-raw-git.sh treats as command
# position, so a flag in the second half of a compound is still seen:
# `jj git fetch && jj git push --allow-new` must be answered about the push.
# Newlines fold to `;` first so multi-line commands split here too.
clauses=$(printf '%s\n' "$command" \
  | tr '\n' ';' \
  | sed -E -e 's/\$\(/;/g' -e 's/[<>]\(/;/g' \
  | tr ';&|' '\n\n\n')

deny() {
  jq -n --arg reason "$1" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
}

# The one subcommand safe to inspect today. See the boundary note above before
# adding another: it is a claim that the subcommand takes no free text.
sub_re='jj[[:space:]]+git[[:space:]]+push([[:space:]]|$)'
sub_cmd='jj git push'

# Take the FIRST offending clause: in a compound the shell reaches it first, and
# answering about a later one would name a command that never ran.
offending=$(printf '%s\n' "$clauses" | grep -E "^[[:space:]]*${sub_re}" | head -n 1)
[ -n "$offending" ] || exit 0

help_text=$($sub_cmd --help 2>&1)
# A --help that produced nothing means jj is broken or unavailable in a way this
# hook cannot reason about. Passing through is the only safe answer: denying on
# an empty help text would reject every flag of a working command.
[ -n "$help_text" ] || exit 0

# Everything after a bare `--` is positional, so a `--word` there is a value and
# not a flag. `jj git push` takes no positionals, which makes this moot for the
# only subcommand in scope today — but the hook would otherwise be right by
# accident rather than by reasoning, and that stops being true the moment the
# scope widens. The pattern needs whitespace-or-end after the `--`, so
# `--bookmark` and friends are untouched.
offending=$(printf '%s' "$offending" | sed -E 's/[[:space:]]--([[:space:]].*)?$//')

# Long flags at word start. `--flag=value` yields `--flag`, since `=` cannot
# continue the name.
flags=$(printf '%s\n' "$offending" \
  | grep -oE '(^|[[:space:]])--[A-Za-z][A-Za-z0-9-]*' \
  | sed 's/^[[:space:]]*//' \
  | sort -u)

for flag in $flags; do
  # Whole-word match against the help text. A substring test would pass
  # `--allow-new` on the strength of `--allow-conflicts`, and pass any
  # abbreviation of a real flag — both of which this is meant to catch.
  # Captured to a variable rather than piped into `grep -q`: under a pipefail
  # shell grep -q exits on first match and the writer takes SIGPIPE, so the
  # pipeline can report failure precisely when the flag WAS found.
  found=$(printf '%s\n' "$help_text" | grep -oE -e "${flag}([^A-Za-z0-9-]|$)" | head -n 1)
  [ -n "$found" ] && continue

  case "$flag" in
    --allow-new)
      deny "BLOCKED: \`${flag}\` is not a flag of \`${sub_cmd}\` in the installed jj.

Pushing a new bookmark is the default now — drop the flag:
  \`jj git push --bookmark <name>\`

Do NOT take jj's own suggestion of \`--all\` here. That pushes EVERY bookmark,
which is not what --allow-new used to do."
      ;;
    *)
      deny "BLOCKED: \`${flag}\` is not a flag of \`${sub_cmd}\` in the installed jj.

Run \`${sub_cmd} --help\` and use a flag it lists. This check reads that help
text directly, so it is describing the binary you are actually running."
      ;;
  esac
  exit 0
done

exit 0
