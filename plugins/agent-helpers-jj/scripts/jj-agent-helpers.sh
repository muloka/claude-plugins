# jj query helpers for agents. Sourced from ~/.zshrc by agent-helpers-jj.
# Bodies are bash+zsh compatible (printf / [ ] / local).
#
# Each function inlines `jj --ignore-working-copy` rather than sharing a private
# `_jjq` helper: Claude Code's shell-snapshot capture (the mechanism that makes
# ~/.zshrc functions callable by the agent's Bash tool) DROPS single-underscore-
# prefixed functions — the zsh completion-function convention. A shared `_jjq`
# would be absent at call time and every helper would fail with "command not
# found: _jjq". Inlining keeps each helper self-contained and snapshot-safe.
#
# --ignore-working-copy: read-only queries must never snapshot the working copy
# (a snapshot writes a new operation to the shared op-log, the serialization
# point concurrent jj workspaces race on).

# jjctx — current change as one JSON object (orientation)
jjctx() { jj --ignore-working-copy log -r @ --no-graph -T 'json(self) ++ "\n"'; }

# jjstack — local changes ahead of trunk, JSON lines
jjstack() { jj --ignore-working-copy log -r 'trunk()..@' --no-graph -T 'json(self) ++ "\n"'; }

# jjconflicts — 0 = clean, 1 = conflicts (printed), >1 = real jj error.
# On jj 0.43 `jj resolve --list` exits 0 (and lists) when conflicts exist, and
# exits 2 ("No conflicts found…") when clean. Distinguishing exit 2 from other
# errors stops an agent reading "clean" from a broken env (not a repo / jj gone).
jjconflicts() {
  local out rc
  out="$(jj --ignore-working-copy resolve --list 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    [ -z "$out" ] && return 0
    printf '%s\n' "$out"; return 1
  fi
  [ "$rc" -eq 2 ] && return 0
  printf 'jjconflicts: jj error (rc=%s)\n' "$rc" >&2
  return "$rc"
}

# jjcheckpoint — current operation id (for a kaisen ledger start-op)
jjcheckpoint() { jj --ignore-working-copy op log -n1 --no-graph -T 'id.short()'; }
