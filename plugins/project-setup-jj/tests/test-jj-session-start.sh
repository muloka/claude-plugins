#!/usr/bin/env bash
set -euo pipefail

# Unit tests for the SessionStart briefing.
#
# The hook emits the only payload every session is guaranteed to read, so these
# tests pin two things:
#   1. CONTENT — it answers stack / conflicts / workspace, and does NOT go back
#      to dumping all of `jj config list`. A briefing that silently loses the
#      conflict line still emits valid JSON and still reads as "working".
#   2. THE SNAPSHOT BUDGET — `jj status` is the one call allowed to snapshot;
#      every other read carries --ignore-working-copy.
#
#      This needs BOTH a behavioural and a structural check, and the behavioural
#      one alone is not enough. Measured while writing these tests: deleting
#      --ignore-working-copy from a read that runs AFTER `jj status` keeps the
#      op count at 1, because the first snapshot already captured the working
#      copy and a second one finds nothing to write. So the op-count assertion
#      pins the property that actually matters to concurrent workspaces — the
#      briefing writes at most one operation — but it CANNOT see a dropped flag.
#      The structural lint below is what catches that.

#
# bash 3.2-safe (macOS): no globstar, no associative arrays.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../scripts/jj-session-start.sh"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

if [ ! -f "$HOOK" ]; then
  echo "  FAIL: hook not found at $HOOK — nothing was checked"
  exit 1
fi

# --- scratch jj repo, fully isolated from the caller's jj config ---
# JJ_CONFIG is not a nicety: a sibling eval scaffold once truncated the caller's
# real ~/.config/jj/config.toml, and every later change carried the wrong author.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export JJ_CONFIG="$WORK/jjconfig.toml"
# trunk() is aliased to a local `main` bookmark so `trunk()..@` means what it
# means in a real repo. Without an origin remote trunk() falls back to the root
# commit, and every change in history would count as "the stack".
#
# immutable_heads() is emptied only so the empty-stack case can be reached at
# all: jj refuses `jj edit trunk()` under the default immutable set, so @ can
# never equal trunk and the stack is never empty. That branch is therefore rare
# in practice — but it is what a briefing prints if a user does loosen the
# immutable set, and a blank section there must not read as "unknown".
cat > "$JJ_CONFIG" <<'CFG'
[user]
name = "test"
email = "test@example.com"

[revset-aliases]
"trunk()" = "main"
"immutable_heads()" = "none()"
CFG
cd "$WORK"
jj git init repo >/dev/null 2>&1
cd repo
echo a > f.txt
jj describe -m seed >/dev/null 2>&1
jj bookmark create main -r @ >/dev/null 2>&1
jj new -m work >/dev/null 2>&1

# ctx -> the briefing's additionalContext string, or empty if the hook emitted
# something that is not valid JSON.
ctx() { bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || true; }

# ops -> current op-log depth. Carries --ignore-working-copy so that MEASURING
# never adds the very operation being measured.
ops() { jj --ignore-working-copy op log --no-graph -T 'id.short() ++ "\n"' 2>/dev/null | grep -c . || true; }

# --- shape ---
raw="$(bash "$HOOK" 2>/dev/null || true)"
if printf '%s' "$raw" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1; then
  ok "emits valid JSON with hookEventName SessionStart"
else
  bad "shape" "not valid SessionStart JSON: $raw"
fi

out="$(ctx)"
if [ -z "$out" ]; then
  bad "additionalContext" "empty — every content assertion below would be vacuous"
fi

# --- content: the three questions the old briefing could not answer ---
case "$out" in
  *"Local stack (trunk()..@):"*) ok "briefing carries the local stack" ;;
  *) bad "stack" "no stack section in briefing" ;;
esac
case "$out" in
  *"Conflicts: none"*) ok "briefing reports conflicts (clean repo -> none)" ;;
  *) bad "conflicts" "no clean-conflict line in briefing" ;;
esac
case "$out" in
  *"Workspaces:"*default:*) ok "briefing names the workspace" ;;
  *) bad "workspaces" "no workspace section in briefing" ;;
esac

# Scope every stack assertion to the stack SECTION, for the reason the identity
# check had to learn: @'s own `json(self)` block sits directly above and already
# contains the description, so an unscoped grep passes even against a hook that
# emits no stack at all.
stack_section=$(printf '%s\n' "$out" | awk '/^Local stack/{f=1;next} /^[[:space:]]*$/{f=0} f')

# The stack is `trunk()..@`, not all of history: it must carry the local change
# and must NOT carry the trunk change it is measured against. A header with the
# wrong revset behind it looks identical until you check both halves.
if [ -z "$stack_section" ]; then
  bad "stack contents" "no stack section — every assertion below would be vacuous"
elif printf '%s' "$stack_section" | grep -qF 'work'; then
  ok "stack section carries the local change, not just a header"
else
  bad "stack contents" "local change absent from the stack section: $stack_section"
fi
if printf '%s' "$stack_section" | grep -qF 'seed'; then
  bad "stack revset" "trunk's own change leaked into the stack — revset is not trunk()..@"
else
  ok "stack excludes trunk itself"
fi

# Compact, not json(self). A depth-1 stack under JSON duplicated @'s object
# verbatim — the exact "spends budget on what changes nothing" the briefing
# exists to avoid — so pin the rendering, not just the contents.
if printf '%s' "$stack_section" | grep -qE '"(commit_id|description|author)"'; then
  bad "stack rendering" "stack regressed to json(self) — it duplicates the section above"
else
  ok "stack renders compact, not JSON"
fi
if printf '%s' "$stack_section" | grep -qF ' @'; then
  ok "stack marks which entry is the working copy"
else
  bad "stack marker" "no @ marker in the stack: $stack_section"
fi

# --- content: identity trimmed to user.email, config trivia gone ---
# Ask jj for the expected value rather than hardcoding the one this test wrote
# into JJ_CONFIG. CI exports JJ_EMAIL, and an env value OUTRANKS the config file,
# so a literal `test@example.com` here passes locally and fails on CI for a
# reason that has nothing to do with the briefing.
want_email=$(jj --ignore-working-copy config get user.email 2>/dev/null || echo "")
# Scope the search to the Identity SECTION. Searching the whole briefing is
# vacuous: every change's `json(self)` already embeds author.email, so deleting
# the Identity section entirely still leaves the address in the payload and the
# assertion passes. Verified by mutation — this check was green against a hook
# with no Identity section at all before it was scoped.
identity_section=$(printf '%s\n' "$out" | awk '/^Identity:/{f=1;next} /^[[:space:]]*$/{f=0} f')
if [ -z "$want_email" ]; then
  bad "identity" "could not read user.email at all — the assertion would be vacuous"
elif [ -z "$identity_section" ]; then
  bad "identity" "no Identity section in the briefing"
elif printf '%s' "$identity_section" | grep -qF "$want_email"; then
  ok "Identity section carries user.email ($want_email)"
else
  bad "identity" "Identity section present but without user.email — the field a clobbered config corrupts"
fi
case "$out" in
  *operation.hostname*|*operation.username*)
    bad "config trim" "briefing regressed to dumping all of jj config list" ;;
  *) ok "config trivia (operation.hostname/username) stays out" ;;
esac

# --- empty stack is stated, not left blank ---
jj edit main >/dev/null 2>&1
out_at_trunk="$(ctx)"
case "$out_at_trunk" in
  *"(none — @ is at trunk)"*) ok "empty stack is stated explicitly" ;;
  *) bad "empty stack" "blank stack section reads as unknown" ;;
esac
jj new -m work2 >/dev/null 2>&1   # back off trunk for the remaining cases

# --- snapshot budget: one snapshot when dirty, none when clean ---
echo dirty >> f.txt          # an unsnapshotted edit, as Write/Edit would leave
before="$(ops)"
bash "$HOOK" >/dev/null 2>&1
after="$(ops)"
delta=$((after - before))
if [ "$delta" -eq 1 ]; then
  ok "dirty working copy -> exactly one operation (jj status snapshots once)"
else
  bad "snapshot budget" "expected 1 new op on a dirty copy, got $delta — a read lost --ignore-working-copy"
fi

before="$(ops)"
bash "$HOOK" >/dev/null 2>&1
after="$(ops)"
delta=$((after - before))
if [ "$delta" -eq 0 ]; then
  ok "clean working copy -> zero operations"
else
  bad "snapshot budget" "expected 0 new ops on a clean copy, got $delta"
fi

# --- structural: only the designated snapshot point may omit the flag ---
# The op-count checks above cannot see this (see header), so read the source.
# Allowed to run unflagged: `jj root` (the repo probe, before any read) and
# `jj status` (the one snapshot point). Everything else must carry the flag.
offenders=""
flagged=0
status_line=0
first_read_line=0
lineno=0
while IFS= read -r line; do
  lineno=$((lineno + 1))
  case "$line" in
    [[:space:]]*"#"*|"#"*) continue ;;      # comments discuss jj freely
  esac
  # Only real call sites, not the word "jj". The briefing's own reminder text
  # says `jj new` / `jj diff`, and a substring match would flag the prose it is
  # the hook's whole job to emit.
  trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
  invocation=0
  case "$line" in
    *'$(jj '*|*'! jj '*) invocation=1 ;;
  esac
  case "$trimmed" in
    'jj '*) invocation=1 ;;
  esac
  if [ "$invocation" -eq 0 ]; then continue; fi
  case "$line" in
    *"--ignore-working-copy"*)
      flagged=$((flagged + 1))
      if [ "$first_read_line" -eq 0 ]; then first_read_line=$lineno; fi
      continue ;;
  esac
  case "$line" in
    *"jj root"*) continue ;;
    *"jj status"*) status_line=$lineno; continue ;;
  esac
  offenders="$offenders  line $lineno: $line
"
done < "$HOOK"

if [ -z "$offenders" ]; then
  ok "every jj read except the probe and the snapshot point carries --ignore-working-copy"
else
  bad "flag discipline" "unflagged jj call(s) outside the snapshot point:
$offenders"
fi

# Fail loudly if the structure this lint depends on vanished: a hook that no
# longer contains the reads would sweep zero lines and report success.
if [ "$flagged" -ge 4 ] && [ "$status_line" -gt 0 ]; then
  ok "lint saw the expected shape ($flagged flagged reads + a snapshot point)"
else
  bad "lint shape" "expected >=4 flagged reads and a jj status line, saw $flagged and line $status_line"
fi

# Ordering: the snapshot must precede the flagged reads, or the briefing mixes
# pre-snapshot and post-snapshot state within one payload.
if [ "$status_line" -gt 0 ] && [ "$status_line" -lt "$first_read_line" ]; then
  ok "snapshot point precedes every --ignore-working-copy read"
else
  bad "ordering" "jj status at line $status_line does not precede first flagged read at $first_read_line"
fi

# --- control characters in a description must not break the payload ---
# escape_for_json handled only \ " \n \r \t and passed every other C0 control
# through raw. JSON forbids ALL of U+0000-U+001F unescaped, and the whole
# briefing is one JSON object — so a single ESC reaching description.first_line()
# cost the ENTIRE payload (stack, conflicts, workspaces, identity), not just the
# offending line. One paste of colorized terminal output into `jj describe` is
# enough to do it.
#
# The emoji rides along deliberately. The fix works byte-wise (LC_ALL=C), so the
# thing most likely to break next is multi-byte UTF-8 being chopped into bytes
# and reassembled wrong — which would corrupt descriptions silently rather than
# loudly, and no JSON parse would catch it. Assert the character survives, not
# just that the payload parses.
cd "$WORK/repo"
jj describe -m "$(printf 'boom\033[31mred \013vt \007bel ship\xf0\x9f\x9a\x80it')" >/dev/null 2>&1
raw_c0="$(bash "$HOOK" 2>/dev/null || true)"
if printf '%s' "$raw_c0" | jq -e . >/dev/null 2>&1; then
  ok "briefing stays valid JSON when a description carries C0 controls"
  if printf '%s' "$raw_c0" | jq -r '.hookSpecificOutput.additionalContext' | grep -q 'ship🚀it'; then
    ok "multi-byte UTF-8 survives the byte-wise escape intact"
  else
    bad "UTF-8" "emoji did not round-trip through escape_for_json"
  fi
else
  bad "C0 escaping" "hook emitted unparseable JSON for a description with ESC/VT/BEL"
fi
jj describe -m work >/dev/null 2>&1

# --- conflicts are surfaced, and loudly ---
# Two siblings editing the same line, merged: @ is a conflicted merge commit.
jj new 'trunk()' -m left >/dev/null 2>&1
echo left > f.txt
left="$(jj --ignore-working-copy log -r @ --no-graph -T 'change_id.short()')"
jj new 'trunk()' -m right >/dev/null 2>&1
echo right > f.txt
right="$(jj --ignore-working-copy log -r @ --no-graph -T 'change_id.short()')"
jj new "$left" "$right" >/dev/null 2>&1

out_conflict="$(ctx)"
case "$out_conflict" in
  *"CONFLICTS PRESENT"*f.txt*) ok "conflicted @ is called out by name" ;;
  *) bad "conflicts" "conflict not surfaced in briefing: $(printf '%s' "$out_conflict" | grep -i conflict || echo '<no conflict line>')" ;;
esac

# --- a broken environment must not read as clean ---
# Outside a jj repo the hook exits silently (0, no output) rather than emitting a
# briefing whose "Conflicts: none" would be a fabrication.
cd "$WORK"
rc=0
outside="$(bash "$HOOK" 2>/dev/null)" || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$outside" ]; then
  ok "outside a jj repo: silent exit 0, no fabricated briefing"
else
  bad "non-repo" "expected silent success, got rc=$rc out='$outside'"
fi

echo
echo "$pass passed, $fail failed"
test "$fail" -eq 0
