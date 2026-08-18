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

# ── Portable stat/date shims (BSD/macOS vs GNU/Linux) ──
#
# GNU must be tried FIRST, and the result must be validated rather than trusted.
# `stat -c` on macOS fails cleanly (non-zero, no output), so the fallback below
# fires correctly. The reverse does not hold: GNU `stat -f` means --file-system,
# and given a FILE it complains about the format string on stderr while still
# printing filesystem info on stdout and exiting 0. A `|| echo 0` fallback
# therefore never fires on Linux — the caller captures a multi-line blob that
# looks like success. That is not a slow statusline, it is a dead one: the blob
# reaches `$(( NOW - CACHE_MTIME ))`, bash reads the word `File:` as a variable
# name, and `set -u` aborts the whole script with no output at all. Hence the
# digit check: exit status is not evidence here, the shape of the value is.
_mtime() {                        # whole seconds, or "" if unresolvable
  local m
  m=$(stat -c '%Y' "$1" 2>/dev/null) || m=$(stat -f '%m' "$1" 2>/dev/null) || m=""
  case "$m" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$m" ;; esac
}

_mtime_ns() {                     # nanosecond precision, or "" if unresolvable
  local m
  m=$(stat -c '%.9Y' "$1" 2>/dev/null) || m=$(stat -f '%Fm' "$1" 2>/dev/null) || m=""
  case "$m" in ''|*[!0-9.]*) printf '' ;; *) printf '%s' "$m" ;; esac
}

_epoch_utc() {                    # ISO8601 (no zone) → epoch seconds, or ""
  local e
  e=$(date -u -d "$1" '+%s' 2>/dev/null) \
    || e=$(TZ=UTC date -jf '%Y-%m-%dT%H:%M:%S' "$1" '+%s' 2>/dev/null) \
    || e=""
  case "$e" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$e" ;; esac
}

input=$(cat)

# Session info from stdin JSON
MODEL=$(echo "$input" | jq -r '.model.display_name // "unknown"')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)

# Quick bail if not a jj repo
if ! jj root --ignore-working-copy >/dev/null 2>&1; then
  SEG_TXT=(" $MODEL "); SEG_BG=("$MDL_BG"); SEG_FG=("$MDL_FG")
  SEG_TXT+=(" ${PCT}% "); SEG_BG+=("$HLT_BG"); SEG_FG+=("$HLT_FG")
  render
  exit 0
fi

# Cache: only re-query jj if repo state changed
# Stores raw pipe-delimited values for segment building
JJ_ROOT="$(jj root --ignore-working-copy 2>/dev/null)"
JJ_DIR="$JJ_ROOT/.jj"

# Cache validity key. `.jj/repo`'s own mtime is NOT a usable signal: it only moves
# when that directory gains an entry (adding a workspace, say), so it can sit frozen
# through hours of commits and serve a permanently stale statusline. This went
# unnoticed only because the $$-keyed filename below meant the cache never hit.
# Track instead the two things the rendered segments actually depend on:
#   op_heads/heads        — bumped by every jj operation (commit, describe, bookmark)
#   working_copy/checkout — bumped when this workspace's working copy is snapshotted
# _mtime_ns is nanosecond-precision, so two operations in the same second still
# differ. In a workspace `.jj/repo` is a FILE holding a relative pointer to the
# main repo directory; in the main repo it is that directory itself.
if [ -d "$JJ_DIR/repo" ]; then
  REPO_DIR="$JJ_DIR/repo"
else
  REPO_DIR="$JJ_DIR/$(cat "$JJ_DIR/repo" 2>/dev/null || echo "")"
fi
OP_MTIME="$(_mtime_ns "$REPO_DIR/op_heads/heads")"
WC_MTIME="$(_mtime_ns "$JJ_DIR/working_copy/checkout")"
if [ -n "$OP_MTIME" ] && [ -n "$WC_MTIME" ]; then
  CACHE_KEY="${OP_MTIME}:${WC_MTIME}"
else
  # Signal unresolvable — e.g. jj changed its internal layout, or neither stat
  # dialect answered. Force a miss rather than risk serving stale state:
  # correctness over speed, never silently wrong.
  CACHE_KEY="uncacheable:$$"
fi

# Key the cache file by repo path, NOT by $$. Claude Code spawns this script as a
# new process on every redraw, so a PID-keyed name never matches on the next run:
# the cache-hit branch below became dead code (all 11 jj queries ran every redraw)
# and each redraw leaked another /tmp file. A cksum collision only degrades to a
# cache miss — CACHE_KEY (repo mtime) still gates validity.
CACHE_DIR="${STATUSLINE_JJ_CACHE_DIR:-/tmp}"
CACHE_FILE="$CACHE_DIR/statusline-jj-$(printf '%s' "$JJ_ROOT" | cksum | cut -d' ' -f1)-cache"

if [ -f "$CACHE_FILE" ] && [ "$(head -1 "$CACHE_FILE")" = "$CACHE_KEY" ]; then
  IFS='|' read -r BOOKMARK CHANGE_ID DESC TRUNK_LABEL TRUNK_CLR < <(tail -1 "$CACHE_FILE") || true
else
  CHANGE_ID=$(jj log --ignore-working-copy -r @ --no-graph -T 'self.change_id().short(8)' 2>/dev/null || echo "")
  DESC=$(jj log --ignore-working-copy -r @ --no-graph -T 'description.first_line()' 2>/dev/null || echo "")
  BOOKMARK=$(jj log --ignore-working-copy -r @ --no-graph -T 'bookmarks' 2>/dev/null || echo "")

  # Trunk state
  ON_TRUNK=$(jj log --ignore-working-copy -r '@ & trunk()' --no-graph -T '"yes"' 2>/dev/null || echo "")
  if [ "$ON_TRUNK" = "yes" ]; then
    TRUNK_LABEL="@trunk"; TRUNK_CLR="healthy"
  else
    AHEAD=$(jj log --ignore-working-copy -r '(trunk()..@) ~ empty()' --no-graph -T '"x"' 2>/dev/null | wc -c | tr -d ' ')
    if [ "$AHEAD" -gt 0 ] 2>/dev/null; then
      TRUNK_LABEL="+${AHEAD}"; TRUNK_CLR="attention"
    else
      ALL=$(jj log --ignore-working-copy -r 'trunk()..@' --no-graph -T '"x"' 2>/dev/null | wc -c | tr -d ' ')
      if [ "$ALL" -gt 0 ] 2>/dev/null; then
        TRUNK_LABEL="@trunk"; TRUNK_CLR="healthy"
      else
        TRUNK_LABEL="⎇"; TRUNK_CLR="attention"
      fi
    fi
  fi

  # Detect if trunk bookmark needs pushing (local ahead of origin)
  for _bm in main master; do
    _ct=$( (jj log --ignore-working-copy -r "${_bm} ~ ${_bm}@origin" --no-graph -T '"x"' 2>/dev/null || true) | wc -c | tr -d ' ')
    if [ "${_ct:-0}" -gt 0 ] 2>/dev/null; then
      TRUNK_LABEL="${TRUNK_LABEL}*"; TRUNK_CLR="attention"
      break
    fi
  done

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
  # An unresolvable mtime must never reach the arithmetic below — treat it as
  # expired and re-fetch. Failing open to 0 here would also read as "expired",
  # but only by accident; an empty value says so deliberately.
  CACHE_MTIME=$(_mtime "$SUMMARY_CACHE")
  NOW=$(date +%s)
  AGE=$(( NOW - ${CACHE_MTIME:-0} ))
  if [ -n "$CACHE_MTIME" ] && [ "$AGE" -lt 300 ]; then
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
    # Skip the badge outright when the timestamp will not parse. Falling back to
    # epoch 0 rendered a confident "⚙ now" for a maintenance window in 1970.
    MAINT_EPOCH=$(_epoch_utc "${MAINT_TIME%%.*}")
    NOW=${NOW:-$(date +%s)}
    DIFF=$(( ${MAINT_EPOCH:-0} - NOW ))
    MAINT_BG="$ATT_BG"; MAINT_FG="$ATT_FG"
    if [ -z "$MAINT_EPOCH" ]; then
      MAINT_TXT=""; MAINT_BG=""; MAINT_FG=""
    elif [ "$DIFF" -gt 86400 ]; then
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
