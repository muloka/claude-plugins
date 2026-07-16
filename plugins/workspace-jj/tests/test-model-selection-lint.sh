#!/usr/bin/env bash
# Lints model-selection directives across every plugin's markdown.
#
# Why this exists: kaisen's Model Selection table is restated in the
# dispatch templates that actually get used. PR #65 fixed the table and missed
# the wave-reviewer template, which went on offering "opus/session" —
# session-model inheritance — for three more PRs. Nothing caught it: source,
# cache, and installed copy all agreed, because they agreed on the unfixed
# text. Prose is not executed, so it is not checked. This checks the one rule
# class where being wrong is silent and only shows up on the bill.
#
# Scope is deliberately narrow. Other skill rules are equally unexecuted; each
# would need its own assertion and its own false-positive analysis.
#
# Usage: test-model-selection-lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PLUGINS="$ROOT/plugins"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); shift; printf '%s\n' "$@" | sed 's/^/    /'; }

# --- Rule 1: no model: directive may offer session-model inheritance ---
#
# An omitted or inherited model silently uses the session's model, usually the
# most capable and most expensive. Every dispatch names its tier.
#
# This reads the whole DIRECTIVE, not just the model: line. A directive wraps
# across continuation lines, and a line-based check cannot see a `session` that
# landed on line 3 of one — which is exactly how the text that prompted this
# lint was written. The directive ends at the next `key:` or a blank line.
hits=$(find "$PLUGINS" -name '*.md' -print0 | while IFS= read -r -d '' f; do
  awk -v f="$f" '
    /^[[:space:]]*model:/ { span=$0; start=NR; inspan=1; next }
    inspan {
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/) {
        inspan=0
        if (span ~ /[Ss]ession/) print f ":" start ": " span
        next
      }
      span = span " " $0
    }
    END { if (inspan && span ~ /[Ss]ession/) print f ":" start ": " span }
  ' "$f"
done)
if [ -z "$hits" ]; then
  ok "no model: directive mentions session"
else
  bad "a model: directive mentions session-model inheritance" "$hits"
fi

# --- Rule 2: the exact #1 shape, anywhere in a file ---
hits=$(grep -rnE '(opus|sonnet|haiku)/session' "$PLUGINS" --include='*.md' || true)
if [ -z "$hits" ]; then
  ok "no file offers <tier>/session"
else
  bad "found <tier>/session — the PR #65 regression" "$hits"
fi

# --- Rule 3: every dispatch block names a model ---
#
# 'Agent tool:' marks a dispatch example. Each must carry a model: line within
# the block, or the example teaches omission by demonstration.
while IFS=: read -r file line _; do
  [ -n "$file" ] || continue
  block=$(sed -n "${line},$((line + 8))p" "$file")
  if printf '%s' "$block" | grep -qE '^[[:space:]]*model:'; then
    ok "dispatch block at $(basename "$file"):$line names a model"
  else
    bad "dispatch block at $(basename "$file"):$line has no model: line" "$block"
  fi
done < <(grep -rn 'Agent tool:' "$PLUGINS" --include='*.md' || true)

echo
echo "$PASS passed, $FAIL failed"
test "$FAIL" -eq 0
