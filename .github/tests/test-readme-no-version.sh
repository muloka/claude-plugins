#!/usr/bin/env bash
set -euo pipefail

# A plugin's version lives in exactly one place: `.claude-plugin/plugin.json`.
#
# That field is machine-checked — #84 fails a PR red if any byte under
# `plugins/<name>/` changes without the manifest version moving — so it is
# trustworthy on every release. A version restated by hand in the README has
# none of that: nothing reads it, nothing checks it, and #84 guarantees the
# manifest moves without it, so the copy drifts by construction on every single
# release.
#
# It is not a hypothetical. All three READMEs that carried this section claimed
# `1.0.0` while their manifests read 0.11.0, 0.10.0 and 0.1.3 — and no plugin has
# ever been at 1.0.0, so the value was never correct, not merely stale. Half the
# plugins never had the section at all, so removing it also settles a convention
# the repo was applying inconsistently.
#
# This lint keys on the HEADING, not on any semver-looking text: a README may
# legitimately say "requires jj 0.43.0", and a lint that fires on that would be
# turned off.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

pass=0
fail=0

readmes=$(find "$REPO_ROOT/plugins" -mindepth 2 -maxdepth 2 -name README.md | sort)
count=$(printf '%s\n' "$readmes" | grep -c . || true)

# A glob that matches nothing passes by doing nothing — the #82 failure. Zero
# READMEs means this lint lost its target, not that the repo is clean.
if [ "$count" -eq 0 ]; then
  echo "  FAIL: found no plugin READMEs — the lint cannot see its target"
  echo ""
  echo "=== Results: 0 passed, 1 failed ==="
  exit 1
fi
echo "  checking $count plugin README(s)"

while IFS= read -r readme; do
  [ -n "$readme" ] || continue
  rel=${readme#"$REPO_ROOT"/}
  hits=$(grep -niE '^#{1,6}[[:space:]]*version[[:space:]]*$' "$readme" || true)
  if [ -n "$hits" ]; then
    fail=$((fail + 1))
    echo "  FAIL: $rel declares a version section by hand"
    printf '        %s\n' "$hits"
    echo "        The manifest is the only source of truth; #84 keeps it honest."
  else
    pass=$((pass + 1))
    echo "  PASS: $rel"
  fi
done <<EOF
$readmes
EOF

echo ""
echo "=== Results: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
  exit 1
fi
