#!/usr/bin/env bash
# jj-aware statusline for Claude Code
# Receives JSON session data on stdin, outputs a single status line
#
# Layout:
#   [Model] bookmark change-id description TRUNK_STATE | N% [2x] status
#
# Trunk states:
#   @trunk  — sitting on trunk
#   +N      — N changes ahead of trunk (linear)
#   ⎇       — divergent (not descended from trunk)
#
# Extras (after context %):
#   2x      — Claude March 2026 2x usage promotion is active
#   ✓/⚠/✗  — Claude Code status (operational/degraded/outage)
#   ⚙ Nd/Nh/Nm — upcoming scheduled maintenance with countdown

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

# 2x window: Claude March 2026 usage promotion
PROMO_BADGE=""
if [ "$(date +%Y-%m)" = "2026-03" ]; then
  PROMO_BADGE="2x"
fi

# Claude status via summary API (cached 5 min, single fetch for all signals)
# Uses /v2/summary.json which includes: components, unresolved incidents, upcoming maintenance
SUMMARY_CACHE="/tmp/statusline-claude-summary"
SUMMARY_JSON=""
if [ -f "$SUMMARY_CACHE" ]; then
  CACHE_MTIME=$(stat -f '%m' "$SUMMARY_CACHE" 2>/dev/null || echo "0")
  NOW=$(date +%s)
  AGE=$(( NOW - CACHE_MTIME ))
  if [ "$AGE" -lt 300 ]; then
    SUMMARY_JSON=$(cat "$SUMMARY_CACHE" 2>/dev/null || echo "")
  fi
fi
if [ -z "$SUMMARY_JSON" ]; then
  SUMMARY_JSON=$(curl -sf --max-time 2 "https://status.claude.com/api/v2/summary.json" 2>/dev/null || echo "")
  if [ -n "$SUMMARY_JSON" ]; then
    printf '%s' "$SUMMARY_JSON" > "$SUMMARY_CACHE"
  fi
fi

CLAUDE_STATUS="?"
MAINT_BADGE=""
if [ -n "$SUMMARY_JSON" ]; then
  # 1. Model-specific incident check (e.g. "Elevated errors on Claude Opus 4.6")
  MODEL_SHORT=$(echo "$MODEL" | sed 's/^Claude //')
  MODEL_INCIDENT=""
  if [ "$MODEL_SHORT" != "unknown" ]; then
    MODEL_INCIDENT=$(echo "$SUMMARY_JSON" | jq -r --arg m "$MODEL_SHORT" \
      '[.incidents[] | select(.name | ascii_downcase | contains($m | ascii_downcase))] | .[0].impact // ""' 2>/dev/null || echo "")
  fi

  if [ -n "$MODEL_INCIDENT" ]; then
    case "$MODEL_INCIDENT" in
      major|critical) CLAUDE_STATUS="✗" ;;
      *)              CLAUDE_STATUS="⚠" ;;
    esac
  else
    # 2. Claude Code component status
    CC_STATUS=$(echo "$SUMMARY_JSON" | jq -r \
      '.components[] | select(.name == "Claude Code") | .status' 2>/dev/null || echo "unknown")
    case "$CC_STATUS" in
      operational)                         CLAUDE_STATUS="✓" ;;
      degraded_performance|partial_outage) CLAUDE_STATUS="⚠" ;;
      major_outage)                        CLAUDE_STATUS="✗" ;;
      *)                                   CLAUDE_STATUS="?" ;;
    esac
  fi

  # 3. Upcoming maintenance warning with countdown
  MAINT_TIME=$(echo "$SUMMARY_JSON" | jq -r '.scheduled_maintenances[0].scheduled_for // ""' 2>/dev/null || echo "")
  if [ -n "$MAINT_TIME" ]; then
    MAINT_EPOCH=$(TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "${MAINT_TIME%%.*}" '+%s' 2>/dev/null || echo "0")
    NOW=${NOW:-$(date +%s)}
    DIFF=$(( MAINT_EPOCH - NOW ))
    if [ "$DIFF" -gt 86400 ]; then
      MAINT_BADGE="⚙ $((DIFF / 86400))d"
    elif [ "$DIFF" -gt 3600 ]; then
      MAINT_BADGE="⚙ $((DIFF / 3600))h"
    elif [ "$DIFF" -gt 60 ]; then
      MAINT_BADGE="⚙ $((DIFF / 60))m"
    elif [ "$DIFF" -gt 0 ]; then
      MAINT_BADGE="⚙ <1m"
    else
      MAINT_BADGE="⚙ now"
    fi
  fi
fi

# Build extras: "2x ✓", "✓ ⚙ 3h", "2x ⚠ ⚙ 3h", etc.
EXTRAS="$CLAUDE_STATUS"
[ -n "$MAINT_BADGE" ] && EXTRAS="$EXTRAS $MAINT_BADGE"
[ -n "$PROMO_BADGE" ] && EXTRAS="$PROMO_BADGE $EXTRAS"

printf '[%s] %s | %s%% %s' "$MODEL" "$JJ_INFO" "$PCT" "$EXTRAS"
