#!/usr/bin/env bash
input=$(cat)

# ── ANSI colors ──
RESET='\033[0m'; BOLD='\033[1m'
CYAN='\033[96m'; GREEN='\033[92m'; YELLOW='\033[93m'
ORANGE='\033[38;5;208m'; RED='\033[91m'; BLUE='\033[94m'
MAGENTA='\033[95m'; GRAY='\033[90m'; WHITE='\033[97m'
SEP="${GRAY} │ ${RESET}"

# ── Data extraction ──
user=$(whoami)
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir_short=$(echo "$dir" | sed "s|$HOME|~|")
raw_model=$(echo "$input" | jq -r '.model.display_name // ""')

# Shorten: "Claude Opus 4.6" → "o4.6"
model=""
if [ -n "$raw_model" ]; then
  prefix=$(echo "$raw_model" | grep -ioE 'Haiku|Sonnet|Opus' | head -1 | cut -c1 | tr '[:upper:]' '[:lower:]')
  version=$(echo "$raw_model" | grep -oE '[0-9]+\.[0-9]+' | tail -1)
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
now=$(date +%H:%M)

# ── Progress bar ──
make_bar() {
  local pct=$1 width=${2:-10}
  local filled=$(echo "$pct $width" | awk '{printf "%d", ($1/100)*$2+0.5}')
  local empty=$(( width - filled ))
  local bar=""
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty;  i++ )); do bar+="░"; done
  printf '%s' "$bar"
}

pct_color() {
  local pct=$1
  if   (( $(echo "$pct < 50" | bc -l) )); then printf '%s' "$GREEN"
  elif (( $(echo "$pct < 75" | bc -l) )); then printf '%s' "$YELLOW"
  elif (( $(echo "$pct < 90" | bc -l) )); then printf '%s' "$ORANGE"
  else printf '%s' "$RED"
  fi
}

# ── Build output ──
out="${BOLD}${CYAN}${user}${RESET}${GRAY} in ${RESET}${WHITE}${dir_short}${RESET}"
[ -n "$git_branch" ] && out+="${GRAY} on ${RESET}${MAGENTA} ${git_branch}${RESET}"
[ -n "$model" ] && out+="${SEP}${BLUE}⬡ ${model}${RESET}"

if [ -n "$used_pct" ]; then
  pct_int=$(printf '%.0f' "$used_pct")
  out+="${SEP}${GRAY}ctx $(pct_color "$used_pct")$(make_bar "$pct_int" 8) ${pct_int}%${RESET}"
fi

if [ -n "$five_pct" ]; then
  pct_int=$(printf '%.0f' "$five_pct")
  reset_str=""
  if [ -n "$five_resets" ]; then
    reset_time=$(date -r "$five_resets" +%H:%M 2>/dev/null || date -d "@$five_resets" +%H:%M 2>/dev/null)
    [ -n "$reset_time" ] && reset_str=" ${GRAY}↺${reset_time}${RESET}"
  fi
  out+="${SEP}${GRAY}5h $(pct_color "$five_pct")$(make_bar "$pct_int" 8) ${pct_int}%${reset_str}${RESET}"
fi

if [ -n "$week_pct" ]; then
  pct_int=$(printf '%.0f' "$week_pct")
  out+="${SEP}${GRAY}7d $(pct_color "$week_pct")$(make_bar "$pct_int" 8) ${pct_int}%${RESET}"
fi

out+="${SEP}${BOLD}${WHITE}${now}${RESET}"
printf '%b' "$out"
