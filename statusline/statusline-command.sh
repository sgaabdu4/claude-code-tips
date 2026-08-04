#!/usr/bin/env bash
input=$(cat)

# ── ANSI colors ──────────────────────────────────────────────
RESET='\033[0m'
BOLD='\033[1m'

# Foreground
WHITE='\033[97m'
CYAN='\033[96m'
GREEN='\033[92m'
YELLOW='\033[93m'
ORANGE='\033[38;5;208m'
RED='\033[91m'
BLUE='\033[94m'
MAGENTA='\033[95m'
GRAY='\033[90m'

SEP="${GRAY} │ ${RESET}"

# ── Data extraction ───────────────────────────────────────────
user=$(whoami)
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir_full="${dir//$HOME/~}"
# Keep only last 2 path segments, prefix with … if shortened
dir_short=$(echo "$dir_full" | awk -F'/' '{
  n=NF
  if (n<=3) { print $0 }
  else { print "…/" $(n-1) "/" $n }
}')
raw_model=$(echo "$input" | jq -r '.model.display_name // ""')

# Shorten: "Claude Sonnet 4.6" → "s4.6", "Claude Opus 5" → "o5", etc. The minor
# is optional: Opus 5 dropped it, and requiring a dot printed the whole name.
model=""
if [ -n "$raw_model" ]; then
  prefix=$(echo "$raw_model" | grep -ioE 'Haiku|Sonnet|Opus' | head -1 | cut -c1 | tr '[:upper:]' '[:lower:]')
  version=$(echo "$raw_model" | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1)
  [ -n "$prefix" ] && [ -n "$version" ] && model="${prefix}${version}"
  [ -z "$model" ] && model="$raw_model"
fi

git_branch=""
if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$dir" symbolic-ref --short HEAD 2>/dev/null \
               || git -C "$dir" rev-parse --short HEAD 2>/dev/null)
fi

used_pct=$(echo "$input"  | jq -r '.context_window.used_percentage // empty')
five_pct=$(echo "$input"  | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input"  | jq -r '.rate_limits.seven_day.used_percentage // empty')

# ── Progress bar helper ───────────────────────────────────────
# Usage: make_bar <pct 0-100> <width>
make_bar() {
  local pct=$1 width=${2:-10}
  local filled
  filled=$(echo "$pct $width" | awk '{printf "%d", ($1/100)*$2+0.5}')
  local empty=$(( width - filled ))
  local bar=""
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done
  printf '%s' "$bar"
}

# ── Color by percentage ───────────────────────────────────────
pct_color() {
  local pct=$1
  if   (( $(echo "$pct < 50" | bc -l) )); then printf '%s' "$GREEN"
  elif (( $(echo "$pct < 75" | bc -l) )); then printf '%s' "$YELLOW"
  elif (( $(echo "$pct < 90" | bc -l) )); then printf '%s' "$ORANGE"
  else printf '%s' "$RED"
  fi
}

# ── Build output ──────────────────────────────────────────────
out=""

# 1. User + dir + branch
out+="${BOLD}${CYAN}${user}${RESET}"
out+="${GRAY} in ${RESET}${WHITE}${dir_short}${RESET}"
if [ -n "$git_branch" ]; then
  out+="${GRAY} on ${RESET}${MAGENTA} ${git_branch}${RESET}"
fi

# 2. Model
if [ -n "$model" ]; then
  out+="${SEP}${BLUE}⬡ ${model}${RESET}"
fi

# 3. Context window
if [ -n "$used_pct" ]; then
  pct_int=$(printf '%.0f' "$used_pct")
  col=$(pct_color "$used_pct")
  bar=$(make_bar "$pct_int" 4)
  out+="${SEP}${GRAY}ctx ${col}${bar} ${pct_int}%${RESET}"
fi

# 4. 5-hour limit
if [ -n "$five_pct" ]; then
  pct_int=$(printf '%.0f' "$five_pct")
  col=$(pct_color "$five_pct")
  bar=$(make_bar "$pct_int" 4)
  reset_str=""
  if [ -n "$five_resets" ]; then
    now_epoch=$(date +%s)
    secs_left=$(( five_resets - now_epoch ))
    if [ "$secs_left" -gt 0 ]; then
      mins_left=$(( secs_left / 60 ))
      h=$(( mins_left / 60 ))
      m=$(( mins_left % 60 ))
      if [ "$h" -gt 0 ]; then
        reset_str=" ${GRAY}↺${h}h${m}m${RESET}"
      else
        reset_str=" ${GRAY}↺${m}m${RESET}"
      fi
    fi
  fi
  out+="${SEP}${GRAY}5h ${col}${bar} ${pct_int}%${reset_str}${RESET}"
fi

# 5. 7-day limit
if [ -n "$week_pct" ]; then
  pct_int=$(printf '%.0f' "$week_pct")
  col=$(pct_color "$week_pct")
  bar=$(make_bar "$pct_int" 4)
  out+="${SEP}${GRAY}7d ${col}${bar} ${pct_int}%${RESET}"
fi

printf '%b' "$out"
