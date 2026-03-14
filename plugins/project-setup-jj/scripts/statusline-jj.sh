#!/usr/bin/env bash
# jj-aware statusline for Claude Code
# Receives JSON session data on stdin, outputs a single status line
#
# Layout:
#   [Model] bookmark change-id description TRUNK_STATE | N%
#
# Trunk states:
#   @trunk  — sitting on trunk
#   +N      — N changes ahead of trunk (linear)
#   ⎇       — divergent (not descended from trunk)

set -euo pipefail

input=$(cat)

# Session info from stdin JSON
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
# Quick bail if not a jj repo
if ! jj root >/dev/null 2>&1; then
  printf '[%s] %s%%' "$MODEL" "$PCT"
  exit 0
fi

# Cache: only re-query jj if repo state changed
CACHE_FILE="/tmp/statusline-jj-$$-cache"
JJ_DIR="$(jj root 2>/dev/null)/.jj"
CACHE_KEY="$(stat -f '%m' "$JJ_DIR/repo" 2>/dev/null || echo "0")"

if [ -f "$CACHE_FILE" ] && [ "$(head -1 "$CACHE_FILE")" = "$CACHE_KEY" ]; then
  JJ_INFO=$(tail -1 "$CACHE_FILE")
else
  CHANGE_ID=$(jj log -r @ --no-graph -T 'self.change_id().short(8)' 2>/dev/null || echo "")
  DESC=$(jj log -r @ --no-graph -T 'description.first_line()' 2>/dev/null || echo "")
  BOOKMARK=$(jj log -r @ --no-graph -T 'bookmarks' 2>/dev/null || echo "")

  # Trunk state detection
  ON_TRUNK=$(jj log -r '@ & trunk()' --no-graph -T '"yes"' 2>/dev/null || echo "")
  if [ "$ON_TRUNK" = "yes" ]; then
    TRUNK_STATE="@trunk"
  else
    # Count non-empty changes between trunk and @
    AHEAD=$(jj log -r '(trunk()..@) ~ empty()' --no-graph -T '"x"' 2>/dev/null | wc -c | tr -d ' ')
    if [ "$AHEAD" -gt 0 ] 2>/dev/null; then
      TRUNK_STATE="+${AHEAD}"
    else
      # All changes are empty — check if descended from trunk at all
      ALL=$(jj log -r 'trunk()..@' --no-graph -T '"x"' 2>/dev/null | wc -c | tr -d ' ')
      if [ "$ALL" -gt 0 ] 2>/dev/null; then
        TRUNK_STATE="@trunk"
      else
        TRUNK_STATE="⎇"
      fi
    fi
  fi

  # Build jj segment: bookmark change-id description trunk-state
  JJ_INFO=""

  # Bookmark (if exists)
  if [ -n "$BOOKMARK" ]; then
    JJ_INFO="$BOOKMARK"
  fi

  # Change ID
  if [ -n "$CHANGE_ID" ]; then
    if [ -n "$JJ_INFO" ]; then
      JJ_INFO="$JJ_INFO $CHANGE_ID"
    else
      JJ_INFO="$CHANGE_ID"
    fi
  fi

  # Description (truncated to 30 chars, or "(no intent)" if empty)
  if [ -n "$DESC" ]; then
    DESC=$(echo "$DESC" | cut -c1-30)
    JJ_INFO="$JJ_INFO $DESC"
  else
    JJ_INFO="$JJ_INFO (no intent)"
  fi

  # Trunk state
  JJ_INFO="$JJ_INFO $TRUNK_STATE"

  # Cache it
  printf '%s\n%s' "$CACHE_KEY" "$JJ_INFO" > "$CACHE_FILE"
fi

printf '[%s] %s | %s%%' "$MODEL" "$JJ_INFO" "$PCT"
