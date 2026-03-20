#!/usr/bin/env bash
# jj-aware statusline for Claude Code — Synthwave powerline edition
# Receives JSON session data on stdin, outputs a single status line
#
# Layout (powerline badges with  transitions):
#   Model  bookmark  change-id  description  TRUNK  N%  2x  status  ⚙ countdown
#
# Requires: Nerd Font / powerline-patched font, 24-bit true color terminal
# Palette: Synthwave — all bg+fg pairs meet WCAG AA contrast

set -euo pipefail

# ── Synthwave palette (24-bit true color) ──
# Each role has: BG (background), FG (text), SF (separator = bg color as foreground)
#
# Model (identity) — lavender #a78bfa / text #1e1035
MDL_BG=$'\033[48;2;167;139;250m'  MDL_FG=$'\033[38;2;30;16;53m'    MDL_SF=$'\033[38;2;167;139;250m'
# Healthy (status/context) — electric cyan #22d3ee / text #083344
HLT_BG=$'\033[48;2;34;211;238m'   HLT_FG=$'\033[38;2;8;51;68m'     HLT_SF=$'\033[38;2;34;211;238m'
# Muted (metadata/no intent) — dark slate #3b3557 / text #9590ad
MUT_BG=$'\033[48;2;59;53;87m'     MUT_FG=$'\033[38;2;149;144;173m'  MUT_SF=$'\033[38;2;59;53;87m'
# Attention (caution) — coral #fb7185 / text #4c0519
ATT_BG=$'\033[48;2;251;113;133m'  ATT_FG=$'\033[38;2;76;5;25m'     ATT_SF=$'\033[38;2;251;113;133m'
# Special (promo) — hot pink #f472b6 / text #500724
SPC_BG=$'\033[48;2;244;114;182m'  SPC_FG=$'\033[38;2;80;7;36m'     SPC_SF=$'\033[38;2;244;114;182m'

R=$'\033[0m'
SEP=$'\uE0B0'

# Map bg escape → separator fg (same RGB, 48→38)
bg2fg() {
  case "$1" in
    "$MDL_BG") printf '%s' "$MDL_SF" ;;
    "$HLT_BG") printf '%s' "$HLT_SF" ;;
    "$MUT_BG") printf '%s' "$MUT_SF" ;;
    "$ATT_BG") printf '%s' "$ATT_SF" ;;
    "$SPC_BG") printf '%s' "$SPC_SF" ;;
    *)         printf '%s' "$R" ;;
  esac
}

# Render SEG_TXT/SEG_BG/SEG_FG arrays as powerline bar
render() {
  local out="" count=${#SEG_TXT[@]} cur_fg
  for (( i=0; i<count; i++ )); do
    out+="${SEG_BG[$i]}${SEG_FG[$i]}${SEG_TXT[$i]}"
    cur_fg=$(bg2fg "${SEG_BG[$i]}")
    if (( i + 1 < count )); then
      out+="${SEG_BG[$((i+1))]}${cur_fg}${SEP}"
    else
      out+="${R}${cur_fg}${SEP}${R}"
    fi
  done
  printf '%s' "$out"
}

input=$(cat)

# Session info from stdin JSON
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Quick bail if not a jj repo
if ! jj root >/dev/null 2>&1; then
  SEG_TXT=(" $MODEL "); SEG_BG=("$MDL_BG"); SEG_FG=("$MDL_FG")
  SEG_TXT+=(" ${PCT}% "); SEG_BG+=("$HLT_BG"); SEG_FG+=("$HLT_FG")
  render
  exit 0
fi

# Cache: only re-query jj if repo state changed
# Stores raw pipe-delimited values for segment building
CACHE_FILE="/tmp/statusline-jj-$$-cache"
JJ_DIR="$(jj root 2>/dev/null)/.jj"
CACHE_KEY="$(stat -f '%m' "$JJ_DIR/repo" 2>/dev/null || echo "0")"

if [ -f "$CACHE_FILE" ] && [ "$(head -1 "$CACHE_FILE")" = "$CACHE_KEY" ]; then
  IFS='|' read -r BOOKMARK CHANGE_ID DESC TRUNK_LABEL TRUNK_CLR < <(tail -1 "$CACHE_FILE") || true
else
  CHANGE_ID=$(jj log -r @ --no-graph -T 'self.change_id().short(8)' 2>/dev/null || echo "")
  DESC=$(jj log -r @ --no-graph -T 'description.first_line()' 2>/dev/null || echo "")
  BOOKMARK=$(jj log -r @ --no-graph -T 'bookmarks' 2>/dev/null || echo "")

  # Trunk state
  ON_TRUNK=$(jj log -r '@ & trunk()' --no-graph -T '"yes"' 2>/dev/null || echo "")
  if [ "$ON_TRUNK" = "yes" ]; then
    TRUNK_LABEL="@trunk"; TRUNK_CLR="healthy"
  else
    AHEAD=$(jj log -r '(trunk()..@) ~ empty()' --no-graph -T '"x"' 2>/dev/null | wc -c | tr -d ' ')
    if [ "$AHEAD" -gt 0 ] 2>/dev/null; then
      TRUNK_LABEL="+${AHEAD}"; TRUNK_CLR="attention"
    else
      ALL=$(jj log -r 'trunk()..@' --no-graph -T '"x"' 2>/dev/null | wc -c | tr -d ' ')
      if [ "$ALL" -gt 0 ] 2>/dev/null; then
        TRUNK_LABEL="@trunk"; TRUNK_CLR="healthy"
      else
        TRUNK_LABEL="⎇"; TRUNK_CLR="attention"
      fi
    fi
  fi

  [ -n "$DESC" ] && DESC=$(echo "$DESC" | cut -c1-30)

  printf '%s\n%s' "$CACHE_KEY" "${BOOKMARK}|${CHANGE_ID}|${DESC}|${TRUNK_LABEL}|${TRUNK_CLR}" > "$CACHE_FILE"
fi

# Map trunk color key → palette role
case "${TRUNK_CLR:-healthy}" in
  healthy)   TRUNK_BG="$HLT_BG"; TRUNK_FG="$HLT_FG" ;;
  attention) TRUNK_BG="$ATT_BG"; TRUNK_FG="$ATT_FG" ;;
  *)         TRUNK_BG="$MUT_BG"; TRUNK_FG="$MUT_FG" ;;
esac

# Context % → healthy / attention gradient
if [ "$PCT" -ge 70 ] 2>/dev/null; then
  PCT_BG="$ATT_BG"; PCT_FG="$ATT_FG"
else
  PCT_BG="$HLT_BG"; PCT_FG="$HLT_FG"
fi

# Claude status via summary API (cached 5 min, single fetch)
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

STATUS_SYM="?"; STATUS_BG="$MUT_BG"; STATUS_FG="$MUT_FG"; STATUS_LBL=""
MAINT_TXT=""; MAINT_BG=""; MAINT_FG=""
if [ -n "$SUMMARY_JSON" ]; then
  # 1. Model-specific incident check
  MODEL_SHORT=$(echo "$MODEL" | sed 's/^Claude //' | sed 's/ ([^)]*)//')
  MODEL_INCIDENT=""
  if [ "$MODEL_SHORT" != "unknown" ]; then
    MODEL_INCIDENT=$(echo "$SUMMARY_JSON" | jq -r --arg m "$MODEL_SHORT" \
      '[.incidents[] | select(.name | ascii_downcase | contains($m | ascii_downcase))] | .[0].impact // ""' 2>/dev/null || echo "")
  fi

  if [ -n "$MODEL_INCIDENT" ]; then
    case "$MODEL_INCIDENT" in
      critical) STATUS_SYM="↯" ;;
      major)    STATUS_SYM="⚠" ;;
      *)        STATUS_SYM="▲" ;;
    esac
    STATUS_BG="$ATT_BG"; STATUS_FG="$ATT_FG"
    STATUS_LBL=$(echo "$MODEL_SHORT" | sed 's/ .*//')  # e.g. "Opus", "Sonnet"
  else
    # 2. Claude Code component status
    CC_STATUS=$(echo "$SUMMARY_JSON" | jq -r \
      '.components[] | select(.name == "Claude Code") | .status' 2>/dev/null || echo "unknown")
    case "$CC_STATUS" in
      operational)          STATUS_SYM="✓"; STATUS_BG="$HLT_BG"; STATUS_FG="$HLT_FG" ;;
      degraded_performance) STATUS_SYM="▲"; STATUS_BG="$ATT_BG"; STATUS_FG="$ATT_FG"; STATUS_LBL="CC" ;;
      partial_outage)       STATUS_SYM="⚠"; STATUS_BG="$ATT_BG"; STATUS_FG="$ATT_FG"; STATUS_LBL="CC" ;;
      major_outage)         STATUS_SYM="↯"; STATUS_BG="$ATT_BG"; STATUS_FG="$ATT_FG"; STATUS_LBL="CC" ;;
      *)                    STATUS_SYM="?"; STATUS_BG="$MUT_BG"; STATUS_FG="$MUT_FG" ;;
    esac
  fi

  # 3. Maintenance countdown
  MAINT_TIME=$(echo "$SUMMARY_JSON" | jq -r '.scheduled_maintenances[0].scheduled_for // ""' 2>/dev/null || echo "")
  if [ -n "$MAINT_TIME" ]; then
    MAINT_EPOCH=$(TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "${MAINT_TIME%%.*}" '+%s' 2>/dev/null || echo "0")
    NOW=${NOW:-$(date +%s)}
    DIFF=$(( MAINT_EPOCH - NOW ))
    MAINT_BG="$ATT_BG"; MAINT_FG="$ATT_FG"
    if [ "$DIFF" -gt 86400 ]; then
      MAINT_TXT="⚙ $((DIFF / 86400))d"
    elif [ "$DIFF" -gt 3600 ]; then
      MAINT_TXT="⚙ $((DIFF / 3600))h"
    elif [ "$DIFF" -gt 60 ]; then
      MAINT_TXT="⚙ $((DIFF / 60))m"
    elif [ "$DIFF" -gt 0 ]; then
      MAINT_TXT="⚙ <1m"
    else
      MAINT_TXT="⚙ now"
    fi
  fi
fi

# ── Build segment arrays (ordered left → right) ──
SEG_TXT=(); SEG_BG=(); SEG_FG=()

SEG_TXT+=(" $MODEL ");    SEG_BG+=("$MDL_BG"); SEG_FG+=("$MDL_FG")

[ -n "$BOOKMARK" ] && {
  SEG_TXT+=(" $BOOKMARK "); SEG_BG+=("$MDL_BG"); SEG_FG+=("$MDL_FG")
}

[ -n "${CHANGE_ID:-}" ] && {
  SEG_TXT+=(" $CHANGE_ID "); SEG_BG+=("$HLT_BG"); SEG_FG+=("$HLT_FG")
}

if [ -n "${DESC:-}" ]; then
  SEG_TXT+=(" $DESC ");       SEG_BG+=("$SPC_BG"); SEG_FG+=("$SPC_FG")
else
  SEG_TXT+=(" (no intent) "); SEG_BG+=("$MUT_BG"); SEG_FG+=("$MUT_FG")
fi

SEG_TXT+=(" ${TRUNK_LABEL:-@trunk} "); SEG_BG+=("${TRUNK_BG}"); SEG_FG+=("${TRUNK_FG}")
SEG_TXT+=(" ${PCT}% ");                SEG_BG+=("$PCT_BG");      SEG_FG+=("$PCT_FG")

# 2x promo: March 13–28, 2026 — weekends + weekdays outside 8am–2pm ET
DAY_NUM=$(date +%d | sed 's/^0//')
DOW=$(date +%u)  # 1=Mon..7=Sun
HOUR_ET=$(TZ=America/New_York date +%H | sed 's/^0//')
if [ "$(date +%Y-%m)" = "2026-03" ] && [ "$DAY_NUM" -ge 13 ] && [ "$DAY_NUM" -le 28 ]; then
  if [ "$DOW" -ge 6 ] || [ "$HOUR_ET" -lt 8 ] || [ "$HOUR_ET" -ge 14 ]; then
    SEG_TXT+=(" 2x "); SEG_BG+=("$SPC_BG"); SEG_FG+=("$SPC_FG")
  fi
fi

STATUS_TXT=" $STATUS_SYM${STATUS_LBL:+ $STATUS_LBL} "
SEG_TXT+=("$STATUS_TXT"); SEG_BG+=("$STATUS_BG"); SEG_FG+=("$STATUS_FG")

[ -n "$MAINT_TXT" ] && {
  SEG_TXT+=(" $MAINT_TXT "); SEG_BG+=("$MAINT_BG"); SEG_FG+=("$MAINT_FG")
}

render
