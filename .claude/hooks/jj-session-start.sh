#!/usr/bin/env bash
# SessionStart hook: Show jj context and workflow reminder
# Outputs JSON with additionalContext for Claude Code
#
# What belongs in this briefing: it is the one payload EVERY session
# reads, so it must answer the questions that change what an agent does next —
# what is in my stack, am I in conflict, which workspace am I in — rather than
# spend its budget on state that changes nothing. It used to emit the whole of
# `jj config list` (four lines of hostname/username/identity) and none of the
# three above. Identity survives the trim as `user.email` alone, because an eval
# scaffold once truncated a caller's ~/.config/jj/config.toml and the wrong
# author on every subsequent change was the symptom nobody saw.
#
# bash 3.2-safe (macOS): no globstar, no associative arrays. Note that under
# `set -e` a bare `[ cond ] && var=x` at top level EXITS the script when cond is
# false — every conditional below is written as if/then for that reason.

set -euo pipefail

# Exit silently if not in a jj repo
if ! jj root >/dev/null 2>&1; then
  exit 0
fi

# `jj status` runs FIRST and deliberately WITHOUT --ignore-working-copy: it is
# the single snapshot point for this briefing. Every read after it carries the
# flag, so (a) the whole briefing describes one consistent post-snapshot state
# instead of a mix of pre- and post-, and (b) the hook writes at most one
# operation to the op log — the serialization point concurrent jj workspaces
# race on (see agent-helpers-jj/scripts/jj-agent-helpers.sh).
working_status=$(jj status 2>/dev/null || echo "(unable to read status)")

current_change=$(jj --ignore-working-copy log -r @ --no-graph -T 'json(self) ++ "\n"' 2>/dev/null || echo "(unable to read current change)")

# The local stack, one compact line per change. NOT `json(self)`: the stack is
# for orientation — which changes am I carrying, are any empty or conflicted —
# and the full object per change buys nothing beyond what the section above
# already prints for @. The common case is a depth-1 stack, where a JSON stack
# repeated @'s object verbatim, ~350 bytes of exact duplication in the one
# payload whose whole justification is not spending budget on what changes
# nothing. A 5-deep stack cost ~1.7KB; the same stack is ~250 bytes here.
#
# Empty output means @ sits at trunk — say so, because a blank section reads as
# "unknown" rather than "nothing there".
_stack_tmpl='self.change_id().short(8)'
_stack_tmpl="$_stack_tmpl"' ++ if(current_working_copy, " @")'
_stack_tmpl="$_stack_tmpl"' ++ if(empty, " [empty]", "")'
_stack_tmpl="$_stack_tmpl"' ++ if(conflict, " [conflict]", "")'
_stack_tmpl="$_stack_tmpl"' ++ if(bookmarks, " (" ++ bookmarks ++ ")", "")'
_stack_tmpl="$_stack_tmpl"' ++ " " ++ if(description, description.first_line(), "(no description)") ++ "\n"'
stack=$(jj --ignore-working-copy log -r 'trunk()..@' --no-graph -T "$_stack_tmpl" 2>/dev/null || echo "(unable to read stack)")
if [ -z "$stack" ]; then
  stack="(none — @ is at trunk)"
fi

# jj 0.43: `resolve --list` exits 0 (and lists) when conflicts exist, and exits
# 2 ("No conflicts found at this revision") when clean. Distinguishing 2 from
# any other non-zero exit stops the briefing reporting "none" out of a broken
# environment — the same discipline as the jjconflicts helper.
conflicts_out=$(jj --ignore-working-copy resolve --list 2>/dev/null) && conflicts_rc=0 || conflicts_rc=$?
if [ "$conflicts_rc" -eq 0 ] && [ -n "$conflicts_out" ]; then
  conflicts="CONFLICTS PRESENT — resolve these before further work:
${conflicts_out}"
elif [ "$conflicts_rc" -eq 0 ] || [ "$conflicts_rc" -eq 2 ]; then
  conflicts="none"
else
  conflicts="(unable to check conflicts — jj exited ${conflicts_rc})"
fi

# @ and `jj root` are workspace-relative: which workspace this session is
# attached to determines what @ even means, and a second live workspace means
# another agent may be editing concurrently.
#
# The template is PINNED, and that is the point of it. jj 0.44 added workspace
# roots to this command's default output, so every briefing silently grew a
# line of reader-relative path noise per workspace at a dependency bump, with
# all suites green. Nothing here parses the output, but it is read by a model
# at the top of every session in every workspace — the most-executed prose the
# plugins ship — so its shape is ours to choose, not jj's to change under us.
# What the briefing actually needs is the concurrency signal: who else is live,
# on which change, and whether that change is empty (nobody mid-work) or not.
workspaces=$(jj --ignore-working-copy workspace list --no-pager \
  -T 'self.name() ++ ": " ++ self.target().change_id().shortest(8) ++ if(self.target().empty(), " (empty)", "") ++ " " ++ if(self.target().description(), self.target().description().first_line(), "(no description set)") ++ "\n"' \
  2>/dev/null || echo "(unable to read workspaces)")

identity=$(jj --ignore-working-copy config list user.email -T 'json(self) ++ "\n"' 2>/dev/null || echo "(unable to read user.email)")

# Escape string for JSON embedding.
#
# The five short forms below are NOT sufficient. JSON forbids every control
# character in U+0000-U+001F unescaped, and this briefing is a single JSON
# object — so one stray control byte does not corrupt one line, it makes the
# whole payload unparseable and the session starts with NO briefing at all: no
# stack, no conflicts, no workspaces, no identity. A jj description picks one up
# trivially, because pasting colorized terminal output into `jj describe` puts an
# ESC (0x1B) into description.first_line(), which line 50 interpolates.
#
# `local LC_ALL=C` makes every string operation in this function byte-wise:
# ${#s} counts bytes, ${s:i:1} takes one byte, and the [ - ] range is byte
# ordering rather than locale collation. Multi-byte UTF-8 therefore survives as
# a run of individual bytes, each >= 0x80 and so passed through untouched, and
# reassembles unchanged. Without the C locale the range would collate and the
# match would be unpredictable.
escape_for_json() {
    local LC_ALL=C
    local s="$1" out="" i ch
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # Fast path: the overwhelmingly common case has nothing left below 0x20, and
    # the byte loop below should not run on every description.
    case "$s" in
      *[$'\001'-$'\037']*) ;;
      *) printf '%s' "$s"; return 0 ;;
    esac
    i=0
    while [ "$i" -lt "${#s}" ]; do
      ch="${s:$i:1}"
      case "$ch" in
        [$'\001'-$'\037']) out="$out$(printf '\\u%04x' "'$ch")" ;;
        *) out="$out$ch" ;;
      esac
      i=$((i+1))
    done
    printf '%s' "$out"
}

context="== jj Session Context ==

Current change (@):
${current_change}

Local stack (trunk()..@):
${stack}

Conflicts: ${conflicts}

Workspaces:
${workspaces}

Working copy status:
${working_status}

Identity:
${identity}

== jj Workflow Reminder ==
- Use \`jj new\` to start a fresh change before making edits
- Use \`jj describe -m \"...\"\` to set intent on the current change
- Use \`jj diff\` to review working copy changes
- Never use raw git commands — use jj equivalents"

escaped_context=$(escape_for_json "$context")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${escaped_context}"
  }
}
EOF

exit 0
