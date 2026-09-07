#!/usr/bin/env bash
# The CLAUDE.md template tells the model how to find workspace-jj's SDD helper
# scripts. That resolution must name the ENABLED plugin, not the highest
# version lying in the cache.
#
# Why: the plugin cache keeps every version ever installed side by side, and
# `claude plugin update` leaves the old directories behind. A cache-wide
# `ls | sort -V | tail -1` therefore picks whatever sorts highest — which is the
# enabled version only until a newer one is cached without being enabled, or an
# older one is re-enabled. Claude Code's own registry of enabled plugins,
# ~/.claude/plugins/installed_plugins.json, records the install path of the
# version actually in use; that is the source. The cache scan stays as the
# fallback for a checkout that has no registry entry (a developer running the
# plugins repo itself).
#
# This test EXECUTES the template's snippet under a sandbox HOME rather than
# grepping for the file name, so a snippet that mentions the registry but
# still resolves from the cache fails here.
#
# bash 3.2-safe: no globstar, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
T="$ROOT/plugins/project-setup-jj/templates/CLAUDE.md.template"
PASS=0
FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# The template carries exactly one fenced bash block: the SDD resolution.
SNIPPET=$(awk '/^```bash$/{f=1;next} /^```$/{f=0} f' "$T")
if [ -z "$SNIPPET" ]; then
  bad "no fenced bash block in the template — nothing to execute"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1
fi
case "$SNIPPET" in
  *SDD=*) ok "template's bash block assigns SDD" ;;
  *) bad "template's bash block does not assign SDD: $SNIPPET" ;;
esac

# resolve <sandbox-home> -> prints what the snippet leaves in $SDD
resolve() {
  HOME="$1" bash -c "$SNIPPET"'
printf "%s" "$SDD"' 2>/dev/null
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- registry names the enabled version; a HIGHER version sits in the cache ---
H1="$WORK/h1"
mkdir -p "$H1/.claude/plugins/cache/mk/workspace-jj/0.5.0/scripts" \
         "$H1/.claude/plugins/cache/mk/workspace-jj/0.9.0/scripts"
cat > "$H1/.claude/plugins/installed_plugins.json" <<EOF
{"version":2,"plugins":{"workspace-jj@mk":[{"scope":"user","installPath":"$H1/.claude/plugins/cache/mk/workspace-jj/0.5.0","version":"0.5.0"}]}}
EOF
got=$(resolve "$H1")
if [ "$got" = "$H1/.claude/plugins/cache/mk/workspace-jj/0.5.0/scripts" ]; then
  ok "enabled 0.5.0 wins over a cached-but-not-enabled 0.9.0"
else
  bad "expected the registry's 0.5.0 scripts dir, got '$got' (cache scan would pick 0.9.0)"
fi

# --- no registry at all -> cache scan fallback, highest version ---
H2="$WORK/h2"
mkdir -p "$H2/.claude/plugins/cache/mk/workspace-jj/0.4.0/scripts" \
         "$H2/.claude/plugins/cache/mk/workspace-jj/0.10.0/scripts"
got=$(resolve "$H2")
if [ "$got" = "$H2/.claude/plugins/cache/mk/workspace-jj/0.10.0/scripts" ]; then
  ok "no registry -> falls back to the cache scan (sort -V picks 0.10.0 over 0.4.0)"
else
  bad "fallback broken: expected 0.10.0 scripts dir, got '$got'"
fi

# --- registry present but its path is gone (pruned cache) -> fallback, not a dead path ---
H3="$WORK/h3"
mkdir -p "$H3/.claude/plugins/cache/mk/workspace-jj/0.5.0/scripts"
cat > "$H3/.claude/plugins/installed_plugins.json" <<EOF
{"version":2,"plugins":{"workspace-jj@mk":[{"scope":"user","installPath":"$H3/.claude/plugins/cache/mk/workspace-jj/0.3.0","version":"0.3.0"}]}}
EOF
got=$(resolve "$H3")
if [ "$got" = "$H3/.claude/plugins/cache/mk/workspace-jj/0.5.0/scripts" ]; then
  ok "registry path missing on disk -> falls back to the cache scan"
else
  bad "stale registry entry not handled: expected the 0.5.0 scripts dir, got '$got'"
fi

# --- registry without any workspace-jj entry -> fallback ---
H4="$WORK/h4"
mkdir -p "$H4/.claude/plugins/cache/mk/workspace-jj/0.5.0/scripts"
printf '{"version":2,"plugins":{"other@mk":[{"scope":"user","installPath":"/nowhere","version":"1.0.0"}]}}\n' > "$H4/.claude/plugins/installed_plugins.json"
got=$(resolve "$H4")
if [ "$got" = "$H4/.claude/plugins/cache/mk/workspace-jj/0.5.0/scripts" ]; then
  ok "registry lacks workspace-jj -> falls back to the cache scan"
else
  bad "missing-entry case: expected the 0.5.0 scripts dir, got '$got'"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
test "$FAIL" -eq 0
