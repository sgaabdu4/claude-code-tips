#!/bin/bash
set -euo pipefail

echo "=== Claude Code Token Optimization Stack ==="
echo "Installing: Headroom + RTK + CBM + context-mode + Caveman + hooks"
echo ""

# ── 1. Install Headroom (includes RTK) ──
echo "→ Installing Headroom..."
pip install "headroom-ai[all]" 2>/dev/null || pip3 install "headroom-ai[all]"

# ── 2. Install codebase-memory-mcp ──
echo "→ Installing codebase-memory-mcp..."
if [[ "$(uname)" == "Darwin" ]]; then
  if [[ "$(uname -m)" == "arm64" ]]; then
    CBM_URL="https://github.com/DeusData/codebase-memory-mcp/releases/latest/download/codebase-memory-mcp-aarch64-apple-darwin"
  else
    CBM_URL="https://github.com/DeusData/codebase-memory-mcp/releases/latest/download/codebase-memory-mcp-x86_64-apple-darwin"
  fi
elif [[ "$(uname)" == "Linux" ]]; then
  CBM_URL="https://github.com/DeusData/codebase-memory-mcp/releases/latest/download/codebase-memory-mcp-x86_64-unknown-linux-gnu"
fi
mkdir -p "$HOME/.local/bin"
curl -fsSL "$CBM_URL" -o "$HOME/.local/bin/codebase-memory-mcp"
chmod +x "$HOME/.local/bin/codebase-memory-mcp"
# Auto-configure for Claude Code
"$HOME/.local/bin/codebase-memory-mcp" setup claude-code 2>/dev/null || true

# ── 3. Install context-mode ──
echo "→ Installing context-mode..."
claude mcp add context-mode -- npx -y context-mode 2>/dev/null || echo "  (run 'claude mcp add context-mode -- npx -y context-mode' manually if this failed)"

# ── 4. Install tvly CLI (Tavily search/extract) ──
echo "→ Installing tvly CLI..."
npm install -g tavily-cli 2>/dev/null || echo "  (run 'npm install -g tavily-cli' manually if this failed)"
echo "  Export TAVILY_API_KEY in your shell rc (get key at tavily.com)."

# ── 5. Create hooks directory ──
echo "→ Creating hooks..."
mkdir -p "$HOME/.claude/hooks"

# ── Hook: bash-ban-raw-tools ──
cat > "$HOME/.claude/hooks/bash-ban-raw-tools" << 'HOOKEOF'
#!/bin/bash
set -euo pipefail
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0
UNLOCK=/tmp/bash-raw-unlock
check_unlock() {
  local f=$1; [ -f "$f" ] || return 1
  local mtime; mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  local age=$(( $(date +%s) - mtime ))
  if [ "$age" -lt 600 ]; then return 0; fi; rm -f "$f"; return 1
}
check_unlock "$UNLOCK" && exit 0
check_unlock "/tmp/bash-raw-unlock-$PPID" && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
TRIMMED=$(echo "$CMD" | sed -E 's/^[[:space:]]*//')
FIRST=$(echo "$TRIMMED" | awk '{print $1}')
banned=0
case "$FIRST" in cat|head|tail|find|grep|rg|wc) banned=1 ;; rtk) exit 0 ;; esac
if echo "$CMD" | grep -qE '\|\s*(tail|head)\b' && echo "$FIRST" | grep -qE '^(cat|grep|rg|find)$'; then
  echo "BLOCKED: pipe truncation. Use ctx_batch_execute instead." >&2; exit 2
fi
[ "$banned" -eq 0 ] && exit 0
case "$FIRST" in
  cat|head|tail) echo "BLOCKED '$FIRST'. Use Read tool." >&2 ;;
  find) echo "BLOCKED 'find'. Use Glob tool." >&2 ;;
  grep|rg) echo "BLOCKED '$FIRST'. Use Grep tool." >&2 ;;
  wc) echo "BLOCKED 'wc'. Use Read." >&2 ;;
esac
exit 2
HOOKEOF

# ── Hook: cbm-code-discovery-gate ──
cat > "$HOME/.claude/hooks/cbm-code-discovery-gate" << 'HOOKEOF'
#!/bin/bash
set -euo pipefail
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
UNLOCK=/tmp/cbm-unlock-$PPID
MARKER=/tmp/cbm-mcp-used-$PPID
[ -f "$UNLOCK" ] && exit 0
find /tmp -maxdepth 1 -name 'cbm-*' -mtime +1 -delete 2>/dev/null || true
case "$TOOL" in
  Grep)
    GLOB=$(echo "$INPUT" | jq -r '.tool_input.glob // ""')
    TYPE=$(echo "$INPUT" | jq -r '.tool_input.type // ""')
    PATH_Q=$(echo "$INPUT" | jq -r '.tool_input.path // ""')
    if [[ "$GLOB" =~ \.(json|yaml|yml|md|toml|lock|txt|env)$ ]] \
      || [[ "$TYPE" =~ ^(json|yaml|md|toml|txt)$ ]] \
      || [[ "$PATH_Q" =~ (\.claude|settings|CLAUDE\.md|/tmp/|/var/) ]]; then exit 0; fi
    echo "BLOCKED Grep on source code. Use codebase-memory-mcp first. Override: touch $UNLOCK." >&2; exit 2 ;;
  Glob)
    PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""')
    if [[ "$PATTERN" =~ \.(dart|ts|tsx|js|jsx|py|go|rs|java|kt|swift)$ ]] \
      || [[ "$PATTERN" =~ ^(lib|src|app)/ ]]; then
      echo "BLOCKED Glob on source tree. Use codebase-memory-mcp first. Override: touch $UNLOCK." >&2; exit 2
    fi ;;
  Read)
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
    if [[ "$FP" =~ \.(json|yaml|yml|md|toml|lock|txt|env|sh)$ ]] \
      || [[ "$FP" =~ (\.claude|CLAUDE\.md|settings|hooks/|/test/|_test\.) ]]; then exit 0; fi
    if [ -f "$MARKER" ]; then
      AGE=$(( $(date +%s) - $(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER" 2>/dev/null || echo 0) ))
      [ "$AGE" -lt 120 ] && exit 0
    fi
    echo "BLOCKED Read on source file. Use codebase-memory-mcp first. Override: touch $UNLOCK." >&2; exit 2 ;;
esac
exit 0
HOOKEOF

# ── Hook: cbm-mcp-marker ──
cat > "$HOME/.claude/hooks/cbm-mcp-marker" << 'HOOKEOF'
#!/bin/bash
set -euo pipefail
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [[ "$TOOL" == mcp__codebase-memory-mcp__* ]]; then
  touch /tmp/cbm-mcp-used-$PPID
fi
exit 0
HOOKEOF

# ── Hook: cbm-session-reminder ──
cat > "$HOME/.claude/hooks/cbm-session-reminder" << 'HOOKEOF'
#!/bin/bash
cat << 'REMINDER'
CRITICAL - Code Discovery Protocol:
1. ALWAYS use codebase-memory-mcp tools FIRST for ANY code exploration:
   - search_graph to find functions/classes/routes
   - trace_path for call chains
   - get_code_snippet to read source
   - query_graph for complex patterns
   - get_architecture for project structure
2. Fall back to Grep/Glob/Read ONLY for non-code files.
3. If a project is not indexed yet, run index_repository FIRST.
REMINDER
HOOKEOF

# Make all hooks executable
chmod +x "$HOME/.claude/hooks/"*

# ── 6. Create statusline script ──
echo "→ Creating statusline..."
cat > "$HOME/.claude/statusline-command.sh" << 'STATUSEOF'
#!/usr/bin/env bash
input=$(cat)
RESET='\033[0m'; BOLD='\033[1m'
CYAN='\033[96m'; GREEN='\033[92m'; YELLOW='\033[93m'
ORANGE='\033[38;5;208m'; RED='\033[91m'; BLUE='\033[94m'
MAGENTA='\033[95m'; GRAY='\033[90m'; WHITE='\033[97m'
SEP="${GRAY} │ ${RESET}"
user=$(whoami)
dir=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
dir_short=$(echo "$dir" | sed "s|$HOME|~|")
raw_model=$(echo "$input" | jq -r '.model.display_name // ""')
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
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
now=$(date +%H:%M)
make_bar() {
  local pct=$1 width=${2:-10} filled=$(echo "$pct $width" | awk '{printf "%d", ($1/100)*$2+0.5}')
  local empty=$(( width - filled )) bar=""
  for (( i=0; i<filled; i++ )); do bar+="█"; done
  for (( i=0; i<empty; i++ )); do bar+="░"; done
  printf '%s' "$bar"
}
pct_color() {
  if (( $(echo "$1 < 50" | bc -l) )); then printf '%s' "$GREEN"
  elif (( $(echo "$1 < 75" | bc -l) )); then printf '%s' "$YELLOW"
  elif (( $(echo "$1 < 90" | bc -l) )); then printf '%s' "$ORANGE"
  else printf '%s' "$RED"; fi
}
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
STATUSEOF

# ── 7. Write settings.json ──
echo "→ Configuring settings.json..."
# Back up existing settings
[ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak.$(date +%s)"

cat > "$HOME/.claude/settings.json" << 'SETTINGSEOF'
{
  "env": {
    "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "70",
    "BASH_MAX_OUTPUT_LENGTH": "10000",
    "MAX_MCP_OUTPUT_TOKENS": "10000",
    "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "ENABLE_PROMPT_CACHING_1H": "1"
  },
  "permissions": {
    "defaultMode": "auto"
  },
  "effortLevel": "medium",
  "advisorModel": "opus",
  "skipDangerousModePermissionPrompt": true,
  "skipAutoPermissionPrompt": true,
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh",
    "refreshInterval": 1000
  },
  "enabledPlugins": {
    "caveman@caveman": true
  },
  "extraKnownMarketplaces": {
    "caveman": {
      "source": {
        "source": "github",
        "repo": "JuliusBrussee/caveman"
      }
    }
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "context-mode hook claude-code pretooluse" },
          { "type": "command", "command": "~/.claude/hooks/bash-ban-raw-tools" }
        ]
      },
      {
        "matcher": "Grep|Glob|Read|Search",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/cbm-code-discovery-gate" }
        ]
      }
    ],
    "PostToolUse": [
      {
        "hooks": [
          { "type": "command", "command": "context-mode hook claude-code posttooluse" },
          { "type": "command", "command": "~/.claude/hooks/cbm-mcp-marker" }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          { "type": "command", "command": "context-mode hook claude-code precompact" }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "context-mode hook claude-code sessionstart" }
        ]
      },
      {
        "matcher": "resume",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/cbm-session-reminder" }
        ]
      },
      {
        "matcher": "clear",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/cbm-session-reminder" }
        ]
      },
      {
        "matcher": "compact",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/cbm-session-reminder" }
        ]
      }
    ]
  }
}
SETTINGSEOF

# ── 8. Add shell wrapper ──
echo "→ Adding shell wrapper for headroom..."

# Fish
if [ -f "$HOME/.config/fish/config.fish" ]; then
  if ! grep -q 'headroom wrap claude' "$HOME/.config/fish/config.fish" 2>/dev/null; then
    cat >> "$HOME/.config/fish/config.fish" << 'FISHEOF'

# Headroom wraps Claude Code for API-layer token compression
function claude
    command headroom wrap claude $argv
end
FISHEOF
    echo "  ✓ Fish config updated"
  else
    echo "  ✓ Fish config already has headroom wrapper"
  fi
fi

# Zsh
if [ -f "$HOME/.zshrc" ]; then
  if ! grep -q 'headroom wrap claude' "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" << 'ZSHEOF'

# Headroom wraps Claude Code for API-layer token compression
claude() { command headroom wrap claude "$@"; }
ZSHEOF
    echo "  ✓ Zsh config updated"
  else
    echo "  ✓ Zsh config already has headroom wrapper"
  fi
fi

# Bash
if [ -f "$HOME/.bashrc" ]; then
  if ! grep -q 'headroom wrap claude' "$HOME/.bashrc" 2>/dev/null; then
    cat >> "$HOME/.bashrc" << 'BASHEOF'

# Headroom wraps Claude Code for API-layer token compression
claude() { command headroom wrap claude "$@"; }
BASHEOF
    echo "  ✓ Bash config updated"
  else
    echo "  ✓ Bash config already has headroom wrapper"
  fi
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "What was installed:"
echo "  ✓ Headroom (API-layer compression, bundles RTK)"
echo "  ✓ codebase-memory-mcp (knowledge graph for code)"
echo "  ✓ context-mode (output virtualization)"
echo "  ✓ Caveman plugin (compressed Claude output)"
echo "  ✓ 5 enforcement hooks"
echo "  ✓ Custom statusline"
echo "  ✓ Optimized settings.json"
echo "  ✓ Shell wrappers (fish/zsh/bash)"
echo ""
echo "Next steps:"
echo "  1. Restart your shell: exec \$SHELL"
echo "  2. Run 'claude' — it now auto-wraps through Headroom"
echo "  3. In a project, CBM will prompt to index on first use"
echo "  4. Run '/caveman' to activate compressed output mode"
echo ""
echo "Repos:"
echo "  Headroom:  https://github.com/chopratejas/headroom"
echo "  CBM:       https://github.com/DeusData/codebase-memory-mcp"
echo "  ctx-mode:  https://github.com/mksglu/context-mode"
echo "  Caveman:   https://github.com/JuliusBrussee/caveman"
echo "  RTK:       https://github.com/rtk-ai/rtk (bundled in Headroom)"
