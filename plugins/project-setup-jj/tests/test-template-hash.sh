#!/usr/bin/env bash
# Verifies the project-setup CLAUDE.md template's hash: marker equals the hash
# of its own body.
#
# Why this exists (#86): /project-setup skips the CLAUDE.md update when the
# installed marker's hash equals the template's. So editing the template body
# without recomputing the hash means the change reaches nobody, while
# /project-setup reports "already up to date". This repo's own CLAUDE.md was
# stale for four months for exactly this reason (#87). The recipe was
# documented in commands/project-setup.md (#85); this makes it executable.
#
# Usage: test-template-hash.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/plugins/project-setup-jj/templates/CLAUDE.md.template"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Portable md5-of-stdin -> first 8 hex (md5 on macOS, md5sum on Linux).
_md5_8() { if command -v md5 >/dev/null 2>&1; then md5; else md5sum; fi | cut -c1-8; }

# --- fail loudly if the structure the check depends on is missing ---
if ! grep -q 'jj-project-setup:start' "$T"; then
  bad "no start marker in $T — cannot verify the hash"
elif ! grep -q 'jj-project-setup:end' "$T"; then
  bad "no end marker in $T — body extraction would be meaningless"
else
  declared=$(sed -n '1s/.*hash:\([0-9a-f][0-9a-f]*\).*/\1/p' "$T")
  if [ -z "$declared" ]; then
    bad "start marker has no parseable hash: — got '$(sed -n '1p' "$T")'"
  else
    recomputed=$(sed -n '/jj-project-setup:start/,/jj-project-setup:end/p' "$T" | sed '1d;$d' | _md5_8)
    if [ "$declared" = "$recomputed" ]; then
      ok "template hash $declared matches its body"
    else
      bad "template hash is stale: marker says $declared, body hashes to $recomputed — rerun the recipe in commands/project-setup.md or the update reaches nobody"
    fi
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
