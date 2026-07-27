#!/usr/bin/env bash
# Drift guard for scripts that are deliberately duplicated across plugins.
#
# Several plugins ship byte-identical copies of the same script so each plugin
# stands alone (block-raw-git.sh in three, jj-workspace-create.sh and
# jj-workspace-remove.sh in two). A fix applied to one copy and not the others
# is silent: the tests exercise one copy, pass, and the stale copies keep
# shipping the old behaviour to whoever installed that plugin. #101 was exactly
# this shape — a security fix that had to land in three places at once.
#
# block-raw-git.sh already had a guard inside its own behaviour test. The other
# two sets had none, so this sweep covers every duplicate by discovery rather
# than by a hand-maintained list: any basename appearing under more than one
# plugin's scripts/ must be byte-identical everywhere it appears.
#
# Intentional divergence is allowed but must be declared in DIVERGENT below, so
# a fork is a visible decision rather than an unnoticed drift. A stale entry
# there is itself a failure — otherwise the allowlist silently grants immunity
# to a set that later stopped being divergent.
#
# Usage: test-script-copy-parity.sh [ROOT]
#   ROOT defaults to the repo root. It is overridable so the guard can be
#   pointed at a scratch tree to prove it actually fails on divergence — see
#   the fail-first note in the commit message.
# bash 3.2-safe: no globstar, no associative arrays.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Basenames intentionally allowed to differ between plugins. Empty today.
DIVERGENT=""

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

cd "$ROOT"

# Fail loudly if the structure this guard depends on is missing, rather than
# sweeping zero files and reporting success — a glob matching nothing is
# indistinguishable from passing (#82).
all_scripts=$(find plugins -path '*/scripts/*.sh' -type f 2>/dev/null | sort)
if [ -z "$all_scripts" ]; then
  bad "no plugin scripts found under $ROOT — nothing was checked"
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  test "$FAIL" -eq 0
fi

duplicated=0
names=$(printf '%s\n' "$all_scripts" | sed 's#.*/##' | sort -u)

for name in $names; do
  copies=$(printf '%s\n' "$all_scripts" | grep "/scripts/$name\$" || true)
  count=$(printf '%s\n' "$copies" | grep -c . || true)
  [ "$count" -gt 1 ] || continue
  duplicated=$((duplicated+1))

  if printf '%s\n' "$DIVERGENT" | grep -qx "$name"; then
    ok "$name is declared intentionally divergent ($count copies, not compared)"
    continue
  fi

  hashes=$(printf '%s\n' "$copies" | xargs shasum -a 256 | awk '{print $1}' | sort -u)
  distinct=$(printf '%s\n' "$hashes" | grep -c .)
  if [ "$distinct" = "1" ]; then
    ok "$name: $count copies share one sha256"
  else
    bad "$name: $count copies have DIVERGED into $distinct versions"
    printf '%s\n' "$copies" | xargs shasum -a 256 | sed 's/^/       /'
  fi
done

# A duplicate set is the only thing this file exists to check. If discovery
# stops finding any, the guard has quietly stopped guarding.
if [ "$duplicated" -gt 0 ]; then
  ok "discovery found $duplicated duplicated script set(s)"
else
  bad "discovery found no duplicated scripts — this guard is no longer guarding anything"
fi

# A stale allowlist entry would silently exempt a set that is no longer
# divergent, so require every declared name to still be duplicated.
for name in $DIVERGENT; do
  [ -n "$name" ] || continue
  count=$(printf '%s\n' "$all_scripts" | grep -c "/scripts/$name\$" || true)
  if [ "$count" -gt 1 ]; then
    ok "DIVERGENT entry '$name' still names a duplicated script"
  else
    bad "DIVERGENT entry '$name' is stale — it names $count copy/copies, so the exemption is dead"
  fi
done

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
