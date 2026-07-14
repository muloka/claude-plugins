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

# race-safety invariant (behavioral): the helpers must NOT snapshot the working
# copy, so they must create no new operations — even when the working copy is
# dirty (an unsnapshotted edit that a plain jj command would snapshot into a new op).
echo dirty > uncommitted.txt
ops() { jj --ignore-working-copy op log --no-graph -T 'id.short() ++ "\n"' | grep -c .; }
before="$(ops)"
jjctx >/dev/null 2>&1 || true
jjstack >/dev/null 2>&1 || true
jjconflicts >/dev/null 2>&1 || true
jjcheckpoint >/dev/null 2>&1 || true
after="$(ops)"
if [ "$before" = "$after" ]; then ok "helpers create no operations (no working-copy snapshot)"; else bad "invariant" "op count $before -> $after (a helper snapshotted)"; fi

# defense in depth: the flag is literally present in the script
if grep -q -- '--ignore-working-copy' "$HELPERS"; then ok "script carries --ignore-working-copy"; else bad "flag" "missing from script"; fi

# drift guard: catalog names == public function names (exclude private _jjq)
defined="$(grep -Eo '^(jj[a-z]+)\(\)' "$HELPERS" | sed 's/()//' | sort -u)"
catalog="$(grep -Eo '`jj[a-z]+' "$TEMPLATE" | tr -d '`' | sort -u)"
if [ "$defined" = "$catalog" ]; then ok "catalog matches defined public functions"; else bad "drift" "defined=[$defined] catalog=[$catalog]"; fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
