# jj query helpers for agents. Sourced from ~/.zshrc by agent-helpers-jj.
# Bodies are bash+zsh compatible (printf / [ ] / local), so the bash test
# harness can source them while they install into zsh.
#
# _jjq is the single place the --ignore-working-copy flag lives: read-only
# queries must never snapshot the working copy (that writes a new operation to
# the shared op-log, the serialization point concurrent jj workspaces race on).

_jjq() { jj --ignore-working-copy "$@"; }

# jjctx — current change as one JSON object (orientation)
jjctx() { _jjq log -r @ --no-graph -T 'json(self) ++ "\n"'; }

# jjstack — local changes ahead of trunk, JSON lines
jjstack() { _jjq log -r 'trunk()..@' --no-graph -T 'json(self) ++ "\n"'; }

# jjconflicts — 0 = clean, 1 = conflicts (printed), >1 = real jj error.
# On jj 0.43 `jj resolve --list` exits 0 (and lists) when conflicts exist, and
# exits 2 ("No conflicts found…") when clean. Distinguishing exit 2 from other
# errors stops an agent reading "clean" from a broken env (not a repo / jj gone).
jjconflicts() {
  local out rc
  out="$(_jjq resolve --list 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$out" ] && return 0
    printf '%s\n' "$out"; return 1
  fi
  [ "$rc" -eq 2 ] && return 0
  printf 'jjconflicts: jj error (rc=%s)\n' "$rc" >&2
  return "$rc"
}

# jjcheckpoint — current operation id (for a fan-flames ledger start-op)
jjcheckpoint() { _jjq op log -n1 --no-graph -T 'id.short()'; }
