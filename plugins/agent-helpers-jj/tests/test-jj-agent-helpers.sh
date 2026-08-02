#!/usr/bin/env bash
set -euo pipefail

# Unit tests for the four jj query helper functions.
# Creates a scratch jj repo, sources the helpers, exercises each function,
# and enforces the --ignore-working-copy race-safety invariant (behaviorally:
# the helpers must create no operations, i.e. never snapshot) + catalog drift.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$SCRIPT_DIR/../scripts/jj-agent-helpers.sh"
TEMPLATE="$SCRIPT_DIR/../templates/jj-agent-helpers-claudemd.md"

pass=0
fail=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1 — $2"; fail=$((fail+1)); }

# --- scratch jj repo ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export JJ_CONFIG="$WORK/jjconfig.toml"
cat > "$JJ_CONFIG" <<'CFG'
[user]
name = "test"
email = "test@example.com"
CFG
cd "$WORK"
jj git init repo >/dev/null 2>&1
cd repo
# seed one described change so trunk()..@ is non-empty. trunk() falls back to
# the root commit when there is no origin remote — fine here, because we assert
# jjstack is NON-empty (a local `main` bookmark would not influence trunk();
# that needs a real main@origin remote, which is more setup than this test needs).
jj describe -m seed >/dev/null 2>&1
jj new >/dev/null 2>&1   # @ is now an empty change on top of the seed

# shellcheck disable=SC1090
. "$HELPERS"

# jjctx: one JSON object carrying a change_id
out="$(jjctx)"
if printf '%s' "$out" | jq -e '.change_id' >/dev/null 2>&1; then ok "jjctx emits JSON with change_id"; else bad "jjctx" "no change_id in: $out"; fi

# jjcheckpoint: non-empty short op id
out="$(jjcheckpoint)"
if [ -n "$out" ]; then ok "jjcheckpoint prints an op id"; else bad "jjcheckpoint" "empty"; fi

# jjstack: JSONL for changes ahead of trunk
out="$(jjstack)"
if [ -n "$out" ] && printf '%s' "$out" | head -1 | jq -e '.change_id' >/dev/null 2>&1; then ok "jjstack emits JSONL ahead of trunk"; else bad "jjstack" "bad: $out"; fi

# jjconflicts: clean repo -> exit 0
if jjconflicts; then ok "jjconflicts exits 0 when clean"; else bad "jjconflicts(clean)" "expected 0"; fi

# jjconflicts: broken env (not a jj repo) -> non-zero, NOT a false clean
( cd "$WORK" && jjconflicts >/dev/null 2>&1 ) && bad "jjconflicts(non-repo)" "returned clean outside a jj repo" || ok "jjconflicts non-zero outside a jj repo"

# race-safety invariant (behavioral): the three QUERY helpers must NOT snapshot
# the working copy, so they must create no new operations — even when the working
# copy is dirty (an unsnapshotted edit a plain jj command would snapshot).
#
# jjcheckpoint is excluded on purpose and asserted the opposite way below: it is
# a restore point, not a query, so it MUST snapshot.
echo dirty > uncommitted.txt
ops() { jj --ignore-working-copy op log --no-graph -T 'id.short() ++ "\n"' | grep -c .; }
before="$(ops)"
jjctx >/dev/null 2>&1 || true
jjstack >/dev/null 2>&1 || true
jjconflicts >/dev/null 2>&1 || true
after="$(ops)"
if [ "$before" = "$after" ]; then ok "query helpers create no operations (no working-copy snapshot)"; else bad "invariant" "op count $before -> $after (a query helper snapshotted)"; fi

# jjcheckpoint MUST snapshot — the inverse of the invariant above.
before="$(ops)"
jjcheckpoint >/dev/null 2>&1 || true
after="$(ops)"
if [ "$before" != "$after" ]; then ok "jjcheckpoint snapshots (op count $before -> $after)"; else bad "jjcheckpoint" "created no operation with a dirty working copy — it is not capturing live edits"; fi

# THE ONE THAT MATTERS: a checkpoint must survive a destructive op and bring the
# working copy back — including edits made with Write/Edit, which never snapshot.
# With --ignore-working-copy this silently returned a pre-edit state (measured
# 2026-08-02); the second arm below proves the flag is what breaks it, so a jj
# change that made the flag harmless would surface here rather than rot.
for arm in shipped with-the-flag; do
  ( cd "$WORK" && rm -rf cp && jj git init cp >/dev/null 2>&1 && cd cp \
    && jj describe -m base >/dev/null 2>&1 \
    && jj new >/dev/null 2>&1 \
    && printf 'committed\n' > tracked.txt \
    && jj describe -m work >/dev/null 2>&1 \
    && printf 'live edit\n' > tracked.txt \
    && printf 'new file\n'  > untracked.txt \
    && if [ "$arm" = shipped ]; then cp_id="$(jjcheckpoint)"
       else cp_id="$(jj --ignore-working-copy op log -n1 --no-graph -T 'id.short()')"; fi \
    && tgt="$(jj log -r @ --no-graph -T 'change_id.short()')" \
    && jj abandon "$tgt" >/dev/null 2>&1 \
    && jj op restore "$cp_id" >/dev/null 2>&1 \
    && [ -f untracked.txt ] && grep -q 'live edit' tracked.txt ) && recovered=yes || recovered=no

  if [ "$arm" = shipped ]; then
    [ "$recovered" = yes ] \
      && ok "jjcheckpoint restore point recovers live (unsnapshotted) edits" \
      || bad "jjcheckpoint" "restoring to its id LOST edits made since the last snapshot"
  else
    [ "$recovered" = no ] \
      && ok "the --ignore-working-copy form loses those edits (why jjcheckpoint omits the flag)" \
      || bad "arm" "--ignore-working-copy no longer costs live edits — the rationale in the script is stale"
  fi
done

# defense in depth: the flag is present for the query helpers, and absent from
# jjcheckpoint. A blanket grep would pass if the flag crept back onto it.
if grep -q -- 'jjctx() {.*--ignore-working-copy' "$HELPERS"; then ok "jjctx carries --ignore-working-copy"; else bad "flag" "missing from jjctx"; fi
if grep -q -- 'jjcheckpoint() {.*--ignore-working-copy' "$HELPERS"; then bad "jjcheckpoint" "--ignore-working-copy crept back — its restore point will exclude live edits"; else ok "jjcheckpoint does not carry --ignore-working-copy"; fi

# drift guard: catalog names == public function names (exclude private _jjq)
defined="$(grep -Eo '^(jj[a-z]+)\(\)' "$HELPERS" | sed 's/()//' | sort -u)"
catalog="$(grep -Eo '`jj[a-z]+' "$TEMPLATE" | tr -d '`' | sort -u)"
if [ "$defined" = "$catalog" ]; then ok "catalog matches defined public functions"; else bad "drift" "defined=[$defined] catalog=[$catalog]"; fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
