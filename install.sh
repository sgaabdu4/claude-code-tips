#!/bin/bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Claude Code Token Optimization Stack installer

Usage:
  ./install.sh [options]

Power-user default:
  Installs Headroom, RTK, CBM, context-mode, Caveman, hooks, commands,
  statusline, settings, and the shell wrapper that runs `claude` through
  Headroom.

Options:
  --check              Validate repo settings/hooks/commands without installing.
  --no-shell-wrapper   Install Headroom, but do not modify your shell rc to wrap `claude`.
  --no-caveman         Skip Caveman plugin install and omit it from merged settings.
  --sonnet             Use `model: sonnet` and `effortLevel: high` instead of Opus/xhigh.
  -h, --help           Show this help.

Examples:
  ./install.sh
  ./install.sh --no-shell-wrapper
  ./install.sh --no-caveman --sonnet
  ./install.sh --check --no-caveman --sonnet
EOF
}

CHECK_ONLY=0
INSTALL_CAVEMAN=1
INSTALL_SHELL_WRAPPER=1
MODEL_PROFILE="power"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --no-shell-wrapper)
      INSTALL_SHELL_WRAPPER=0
      shift
      ;;
    --no-caveman)
      INSTALL_CAVEMAN=0
      shift
      ;;
    --sonnet)
      MODEL_PROFILE="sonnet"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 2
      ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_SOURCE="$REPO_DIR/settings/settings.json"
SETTINGS_TMP=""

WIN_TMP=""

cleanup_tmp() {
  [[ -n "${SETTINGS_TMP:-}" ]] && rm -f "$SETTINGS_TMP"
  [[ -n "${WIN_TMP:-}" ]] && rm -f "$WIN_TMP"
  return 0
}
trap cleanup_tmp EXIT

prepare_settings_source() {
  local filter='.'

  if [[ "$INSTALL_CAVEMAN" -eq 0 ]]; then
    filter="$filter | del(.enabledPlugins[\"caveman@caveman\"]) | del(.extraKnownMarketplaces.caveman)"
  fi

  if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
    filter="$filter | .model = \"sonnet\" | .effortLevel = \"high\""
  fi

  if [[ "$filter" != "." ]]; then
    SETTINGS_TMP="$(mktemp)"
    jq "$filter" "$REPO_DIR/settings/settings.json" > "$SETTINGS_TMP"
    SETTINGS_SOURCE="$SETTINGS_TMP"
  fi
}

# ── Validator mode ──
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "=== install.sh --check ==="
  fail=0
  warn=0

  # 1. JSON syntax
  if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not installed (required by hooks + check mode)"; fail=1
  else
    prepare_settings_source
    if ! jq empty "$SETTINGS_SOURCE" 2>/dev/null; then
      echo "FAIL: settings/settings.json is not valid JSON"; fail=1
    fi
  fi

  # 2. Every hook command in settings resolves — both halves of it:
  #    a) ~/.claude/hooks/* paths must exist as files in repo hooks/
  #    b) the CLI a hook ultimately runs must be findable on a hook's PATH.
  #    (b) is the check that was missing: hooks are spawned without the user's
  #    shell rc, so a bare `rtk hook claude` died with ENOENT while --check
  #    still printed OK. See issue #2.
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r cmd; do
      # jq.exe writes CRLF to stdout under Git Bash, so every line arrives with
      # a trailing CR that silently corrupts the hook path we build from it.
      cmd="${cmd%$'\r'}"
      [[ -z "$cmd" ]] && continue
      read -r head arg1 _ <<<"$cmd"
      hook_path="${head//\~/$HOME}"
      if [[ "$hook_path" == "$HOME/.claude/hooks/"* ]]; then
        hook_name="${hook_path##*/}"
        if [[ ! -f "$REPO_DIR/hooks/$hook_name" ]]; then
          echo "FAIL: settings.json references hook '$hook_name' but $REPO_DIR/hooks/$hook_name missing"; fail=1
          continue
        fi
        # Shim form `run-cli-hook <bin> ...` — the dispatched CLI must resolve.
        [[ "$hook_name" == "run-cli-hook" && -n "$arg1" ]] || continue
        bin="$arg1"
      else
        bin="$head"
      fi
      # Absolute paths and shell interpreters are not our lookup problem.
      [[ "$bin" == /* || "$bin" == bash || "$bin" == sh ]] && continue
      if ! "$REPO_DIR/hooks/run-cli-hook" --which "$bin" >/dev/null 2>&1; then
        echo "WARN: hook '$cmd' needs '$bin', not found on PATH or in any known install dir"
        echo "      → install it, or set CCT_$(echo "$bin" | tr '[:lower:].-' '[:upper:]__')_BIN to its absolute path"
        warn=$((warn + 1))
      fi
    done < <(jq -r '[.. | objects | select(.command? != null) | .command] | .[]' "$SETTINGS_SOURCE")
  fi

  # 3. Every commands/*.md plugin reference resolves to an enabled plugin
  while IFS= read -r f; do
    while IFS= read -r ref; do
      plugin="${ref#mcp__plugin_}"
      plugin="${plugin%%_*}"
      if ! jq -e --arg p "$plugin" '.enabledPlugins | keys[] | select(startswith($p))' "$SETTINGS_SOURCE" >/dev/null 2>&1; then
        echo "FAIL: $f references mcp__plugin_${plugin}_* but no '$plugin@*' enabled in settings"; fail=1
      fi
    done < <(grep -oE 'mcp__plugin_[a-z0-9_-]+' "$f" 2>/dev/null | sort -u)
  done < <(find "$REPO_DIR/commands" -name '*.md' 2>/dev/null)

  # 4. bin/ scripts referenced by hooks must exist
  for script in sync-copilot.mjs sync-runner-tools.mjs; do
    if grep -rqE "bin/$script" "$REPO_DIR/hooks/" 2>/dev/null; then
      [[ -f "$REPO_DIR/bin/$script" ]] || { echo "FAIL: hooks reference bin/$script but $REPO_DIR/bin/$script missing"; fail=1; }
    fi
  done

  if [[ $fail -eq 0 ]]; then
    if [[ $warn -gt 0 ]]; then
      echo "OK: all hooks, command plugin refs, and bin/ scripts resolve ($warn warning(s) above)"
    else
      echo "OK: all hooks, command plugin refs, and bin/ scripts resolve"
    fi
    exit 0
  fi
  exit 1
fi

echo "=== Claude Code Token Optimization Stack ==="
echo "Installing: Headroom + RTK + CBM + context-mode + hooks"
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "Power-user output compression: Caveman enabled"
else
  echo "Power-user output compression: Caveman skipped (--no-caveman)"
fi
if [[ "$INSTALL_SHELL_WRAPPER" -eq 1 ]]; then
  echo "Shell wrapper: enabled (claude → headroom wrap claude)"
else
  echo "Shell wrapper: skipped (--no-shell-wrapper)"
fi
if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
  echo "Model profile: sonnet/high (--sonnet)"
else
  echo "Model profile: opus/xhigh"
fi
echo ""

# ── 0. Sanity-check required tools ──
# Hooks rely on jq; install.sh's --check validator does too. Catch missing
# tools up front with one clear message rather than cryptic errors mid-run.
missing=""
for cmd in git curl jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
if [[ -n "$missing" ]]; then
  echo "❌ Missing required tools:$missing"
  echo "   macOS:  brew install$missing"
  echo "   Debian: sudo apt-get install -y$missing"
  echo "   Re-run install.sh once they are on PATH."
  exit 1
fi

prepare_settings_source

# ── 0. Platform detection ──
# Git Bash / MSYS2 / Cygwin all report a MINGW*-flavoured uname but download
# Windows binaries. Recorded once here so every installer step agrees, and so
# the closing summary can report what actually landed instead of assuming.
OS_NAME=""
OS_ARCH=""
case "$(uname)" in
  Darwin)                  OS_NAME="darwin" ;;
  Linux)                   OS_NAME="linux" ;;
  MINGW*|MSYS*|CYGWIN*)    OS_NAME="windows" ;;
  *) echo "⚠ Unsupported OS: $(uname). Binary installs will be skipped." ;;
esac
case "$(uname -m)" in
  arm64|aarch64)  OS_ARCH="arm64" ;;
  x86_64|amd64)   OS_ARCH="amd64" ;;
  *) echo "⚠ Unsupported arch: $(uname -m). Binary installs will be skipped." ;;
esac

STATUS_HEADROOM="skipped"
STATUS_RTK="skipped"
STATUS_CBM="skipped"

# Git for Windows ships no unzip(1); python3 is already a hard dependency.
extract_zip() { # extract_zip <archive> <dest>
  if command -v unzip >/dev/null 2>&1; then
    unzip -qo "$1" -d "$2"
  else
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
  fi
}

# ── 1. Install Headroom ──
# Headroom used to vendor RTK; headroomlabs-ai/headroom#2677 (merged 2026-07-31)
# removed it with no replacement and no cleanup path. RTK is installed on its
# own below.
# `--user` keeps us off the system Python and dodges PEP 668
# "externally-managed-environment" errors on Homebrew Python 3.11+ /
# Debian-flavour distros. Falls back to plain pip if --user is unsupported
# (e.g. a venv where --user makes no sense).
echo "→ Installing Headroom..."
HR_CMD=""
if command -v pip3 >/dev/null 2>&1; then HR_CMD="pip3"
elif command -v pip  >/dev/null 2>&1; then HR_CMD="pip"
fi
if [[ -n "$HR_CMD" ]]; then
  if "$HR_CMD" install --user "headroom-ai[all]" 2>/dev/null \
     || "$HR_CMD" install "headroom-ai[all]" 2>/dev/null; then
    STATUS_HEADROOM="ok"
  else
    echo "  ⚠ pip install failed. Run manually: $HR_CMD install --user 'headroom-ai[all]'"
  fi
else
  echo "  ⚠ pip / pip3 not found — install Python 3 + pip, then run: pip install --user 'headroom-ai[all]'"
fi

# ── 1b. Install RTK ──
# Resolve it the way a hook does first, so an existing copy (Homebrew, cargo,
# a leftover ~/.headroom/bin one) is reused instead of installing a second
# binary that shadows it.
echo "→ Installing RTK..."
if existing_rtk=$("$REPO_DIR/hooks/run-cli-hook" --which rtk 2>/dev/null); then
  echo "  ✓ rtk already resolves → $existing_rtk"
  STATUS_RTK="ok"
elif [[ "$OS_NAME" == "windows" ]]; then
  # Upstream's install.sh rejects MINGW outright, but the release does ship a
  # Windows build, so fetch that directly.
  if [[ "$OS_ARCH" != "amd64" ]]; then
    echo "  ⚠ rtk publishes no Windows $OS_ARCH build. Skipping."
  else
    RTK_TMP="$(mktemp -d)"
    RTK_URL="https://github.com/rtk-ai/rtk/releases/latest/download/rtk-x86_64-pc-windows-msvc.zip"
    mkdir -p "$HOME/.local/bin"
    if curl -fsSL "$RTK_URL" -o "$RTK_TMP/rtk.zip" && extract_zip "$RTK_TMP/rtk.zip" "$RTK_TMP"; then
      rtk_exe="$(find "$RTK_TMP" -name 'rtk.exe' -type f | head -1)"
      if [[ -n "$rtk_exe" ]]; then
        mv "$rtk_exe" "$HOME/.local/bin/rtk.exe"
        chmod +x "$HOME/.local/bin/rtk.exe"
        echo "  ✓ rtk installed at ~/.local/bin/rtk.exe"
        STATUS_RTK="ok"
      else
        echo "  ⚠ rtk archive extracted but rtk.exe not found"
      fi
    else
      echo "  ⚠ rtk download failed ($RTK_URL)"
    fi
    rm -rf "$RTK_TMP"
  fi
elif command -v brew >/dev/null 2>&1; then
  if brew install rtk 2>/dev/null; then
    STATUS_RTK="ok"
  else
    echo "  ⚠ brew install rtk failed. Run manually: brew install rtk"
  fi
else
  if curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh; then
    STATUS_RTK="ok"
  else
    echo "  ⚠ rtk install script failed. See https://github.com/rtk-ai/rtk"
  fi
fi

# ── 2. Install codebase-memory-mcp ──
# Releases ship as <name>-<os>-<arch>.{tar.gz,zip}. We download, extract the
# binary, and drop it in ~/.local/bin (caller is expected to have ~/.local/bin
# on PATH).
echo "→ Installing codebase-memory-mcp..."
if [[ -n "$OS_NAME" && -n "$OS_ARCH" ]]; then
  if [[ "$OS_NAME" == "windows" ]]; then
    CBM_EXT="zip"; CBM_BIN="codebase-memory-mcp.exe"
  else
    CBM_EXT="tar.gz"; CBM_BIN="codebase-memory-mcp"
  fi
  CBM_URL="https://github.com/DeusData/codebase-memory-mcp/releases/latest/download/codebase-memory-mcp-${OS_NAME}-${OS_ARCH}.${CBM_EXT}"
  mkdir -p "$HOME/.local/bin"
  CBM_TMP="$(mktemp -d)"
  if curl -fsSL "$CBM_URL" -o "$CBM_TMP/cbm.$CBM_EXT"; then
    if [[ "$CBM_EXT" == "zip" ]]; then
      extract_zip "$CBM_TMP/cbm.zip" "$CBM_TMP" 2>/dev/null || true
    else
      tar -xzf "$CBM_TMP/cbm.tar.gz" -C "$CBM_TMP"
    fi
    if [[ -f "$CBM_TMP/$CBM_BIN" ]]; then
      mv "$CBM_TMP/$CBM_BIN" "$HOME/.local/bin/$CBM_BIN"
      chmod +x "$HOME/.local/bin/$CBM_BIN"
      # </dev/null is load-bearing. `setup claude-code` does not configure and
      # return — as of 0.9.0 it starts the MCP server in stdio mode and reads
      # stdin forever, so inheriting a live stdin hangs the installer here with
      # no output. Closing stdin gives it EOF and it shuts down. CI never caught
      # it because a runner hands the step an already-closed stdin. Issue #2.
      "$HOME/.local/bin/$CBM_BIN" setup claude-code </dev/null >/dev/null 2>&1 || true
      echo "  ✓ CBM installed at ~/.local/bin/$CBM_BIN"
      STATUS_CBM="ok"
    else
      echo "  ⚠ CBM archive extracted but $CBM_BIN not found — open an issue at the repo"
    fi
  else
    echo "  ⚠ CBM download failed ($CBM_URL). Skip and run manually later."
  fi
  rm -rf "$CBM_TMP"
fi

# ── 3. Install Claude Code plugins (context-mode + optional caveman) ──
# Plugin install (not raw `mcp add`) so context-mode tools resolve under
# `mcp__plugin_context-mode_context-mode__*` — the namespace slash commands
# (/e2e, /unleash) reference. Raw `mcp add` produces `mcp__context-mode__*`
# which the slash commands cannot find. Caveman stays enabled by default for
# the power-user profile, but --no-caveman keeps private style choices out of
# the merged settings.
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "→ Installing Claude Code plugins (context-mode, caveman)..."
else
  echo "→ Installing Claude Code plugins (context-mode only; Caveman skipped)..."
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "  ⚠ 'claude' CLI not on PATH. Skip plugin install — install Claude Code first, then run:"
  echo "    claude plugin marketplace add mksglu/context-mode && claude plugin install context-mode@context-mode"
  if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
    echo "    claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman"
  fi
else
  claude plugin marketplace add mksglu/context-mode </dev/null 2>/dev/null \
    || echo "  (run 'claude plugin marketplace add mksglu/context-mode' manually if this failed)"
  claude plugin install context-mode@context-mode </dev/null 2>/dev/null \
    || echo "  (run 'claude plugin install context-mode@context-mode' manually if this failed)"
  if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
    claude plugin marketplace add JuliusBrussee/caveman </dev/null 2>/dev/null \
      || echo "  (run 'claude plugin marketplace add JuliusBrussee/caveman' manually if this failed)"
    claude plugin install caveman@caveman </dev/null 2>/dev/null \
      || echo "  (run 'claude plugin install caveman@caveman' manually if this failed)"
  fi
fi

# Global context-mode CLI: the plugin registers the MCP tools but does NOT put
# the `context-mode` binary on PATH. The hooks in settings/settings.json call
# `context-mode hook claude-code <event>`, so the global CLI is required —
# without it those hooks fail with "command not found".
echo "→ Installing context-mode CLI (hook dispatcher binary)..."
# A vendored or version-managed copy earlier in PATH shadows whatever npm puts
# in the global prefix, so `npm install -g` would leave a second copy that the
# hooks never run — an upgrade that looks like it worked and didn't. If the CLI
# already resolves, leave it to whatever owns it.
if existing_cm=$("$REPO_DIR/hooks/run-cli-hook" --which context-mode 2>/dev/null); then
  echo "  ✓ context-mode already resolves → $existing_cm"
  echo "    Skipping 'npm install -g' so we don't create a shadowed second copy."
elif command -v npm >/dev/null 2>&1; then
  npm install -g context-mode 2>/dev/null \
    || echo "  ⚠ npm install -g context-mode failed — run manually after this script."
else
  echo "  ⚠ npm not found — install Node.js (https://nodejs.org), then 'npm install -g context-mode'."
fi

# ── 4. Install tvly CLI (Tavily search/extract) ──
echo "→ Installing tvly CLI..."
if command -v npm >/dev/null 2>&1; then
  npm install -g tavily-cli 2>/dev/null \
    || echo "  ⚠ npm install -g tavily-cli failed — run manually after this script."
else
  echo "  ⚠ npm not found — install Node.js (https://nodejs.org), then 'npm install -g tavily-cli'."
fi
echo "  Export TAVILY_API_KEY in your shell rc (get key at tavily.com)."

# ── Helpers for safe install over an existing setup ──
# cp_with_backup: if target file exists AND differs from source, rename target
# to <name>.bak.<ts> before overwrite. No-op when target is missing or already
# identical. Surfaces user customizations as backups instead of silently nuking.
cp_with_backup() {
  local src="$1"; local dst="$2"
  if [[ -f "$dst" ]] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "$dst.bak.$(date +%s).$$"
  fi
  cp "$src" "$dst"
}

# inject_claude_md: prepend our framework content into ~/.claude/CLAUDE.md
# wrapped in <!--cct--> ... <!--/cct--> markers. Re-runs replace the block in
# place — user's content outside the markers is preserved verbatim.
inject_claude_md() {
  local target="$HOME/.claude/CLAUDE.md"
  local source="$REPO_DIR/CLAUDE.md.example"
  local m_start='<!--cct-->'
  local m_end='<!--/cct-->'

  # Helper: write start marker + source body + always-newline + end marker.
  # Forces a newline before $m_end so the marker lives on its own line, even
  # when $source lacks a trailing newline (otherwise re-run awk can't match it).
  _write_block() {
    echo "$m_start"
    cat "$source"
    # `$(tail -c 1)` strips a trailing \n (command substitution always does),
    # so an EMPTY captured string means the file ends in \n (no echo needed).
    # Anything non-empty means the last byte is non-\n (echo to add one).
    [[ -z "$(tail -c 1 "$source" 2>/dev/null)" ]] || echo
    echo "$m_end"
  }

  if [[ ! -f "$target" ]]; then
    _write_block > "$target"
    echo "  ✓ CLAUDE.md created (wrapped in <!--cct--> markers for future updates)"
    return
  fi

  # Symlink guard: if target is a symlink, refuse to stomp it via `mv` (which
  # would replace the symlink with a regular file and orphan whatever it
  # points at — e.g., a dotfiles-repo file). Resolve to the real path first.
  if [[ -L "$target" ]]; then
    local resolved
    resolved="$(readlink -f "$target" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target")"
    echo "  ℹ CLAUDE.md is a symlink → $resolved (editing the real file)"
    target="$resolved"
  fi

  # Orphaned-marker guard: if start marker exists but end marker does NOT,
  # awk would silently drop everything after $m_start. Bail loud instead.
  if grep -qF "$m_start" "$target" && ! grep -qF "$m_end" "$target"; then
    echo "  ✗ CLAUDE.md has <!--cct--> start marker but no <!--/cct--> end marker."
    echo "    Refusing to write — fix manually or delete the start marker. Aborting."
    return 1
  fi

  # Per-invocation backup suffix (epoch seconds + PID) — survives concurrent runs.
  local backup_suffix
  backup_suffix="$(date +%s).$$"

  # Build candidate output to .tmp, only swap (+ backup) if content differs.
  if grep -qF "$m_start" "$target"; then
    awk -v ms="$m_start" -v me="$m_end" -v src="$source" '
      $0 == ms {
        print
        while ((getline line < src) > 0) print line
        close(src)
        # If src lacked trailing newline, last line was still printed (awk adds \n).
        # That is fine — print the end marker on its own line next.
        skip=1; next
      }
      $0 == me { print; skip=0; next }
      !skip { print }
    ' "$target" > "$target.tmp"
    if cmp -s "$target" "$target.tmp"; then
      rm -f "$target.tmp"
      echo "  ✓ CLAUDE.md <!--cct--> block already up to date"
    else
      cp "$target" "$target.bak.$backup_suffix"
      mv "$target.tmp" "$target"
      echo "  ✓ CLAUDE.md <!--cct--> block updated (your content outside markers preserved)"
    fi
  else
    { _write_block; echo ""; cat "$target"; } > "$target.tmp"
    if cmp -s "$target" "$target.tmp"; then
      rm -f "$target.tmp"
      echo "  ✓ CLAUDE.md already up to date"
    else
      cp "$target" "$target.bak.$backup_suffix"
      mv "$target.tmp" "$target"
      echo "  ✓ CLAUDE.md prepended (your existing content kept below <!--cct--> block)"
    fi
  fi
}

# merge_settings_json: deep jq merge. Preserves user model/effortLevel/
# permissions/custom env by default. Replaces hooks structure (we own it).
# Unions enabledPlugins + extraKnownMarketplaces, with explicit CLI flags allowed
# to remove Caveman or force the sonnet/high model profile.
# Falls back to plain copy if jq fails.

# A hook command has to survive whichever shell Claude Code spawns it with. On
# Windows that is not settled: cmd.exe expands neither `~` nor a shebang, so
# `~/.claude/hooks/x` dies there while running fine under Git Bash. An absolute
# bash.exe plus an absolute script path works under both, verified in CI.
# A bare `bash` is not safe here — System32\bash.exe, the WSL launcher, often
# sits ahead of Git's on PATH and would run the hook against a different
# filesystem entirely.
winify_settings() { # winify_settings <in> <out>
  local bash_abs home_abs
  command -v cygpath >/dev/null 2>&1 || return 1
  bash_abs="$(cygpath -m "$(command -v bash)" 2>/dev/null)" || return 1
  home_abs="$(cygpath -m "$HOME" 2>/dev/null)" || return 1
  [[ -n "$bash_abs" && -n "$home_abs" ]] || return 1
  jq --arg bash "$bash_abs" --arg home "$home_abs" '
    def winify:
      (if startswith("bash ~/") then .[5:] else . end) as $c
      | if ($c | startswith("~/")) then
          # Split before substituting: the ~ form has no spaces, an expanded
          # C:/Users/First Last home does.
          ($c | split(" ")) as $t
          | ($t[0] | sub("^~"; $home)) as $script
          | ($t[1:] | join(" ")) as $rest
          | "\"\($bash)\" \"\($script)\"" + (if $rest == "" then "" else " \($rest)" end)
        else . end;
    walk(if type == "object" and (.command? | type) == "string"
         then .command |= winify else . end)
  ' "$1" > "$2"
}

merge_settings_json() {
  local target="$HOME/.claude/settings.json"
  local source="$SETTINGS_SOURCE"
  local skip_caveman=false
  [[ "$INSTALL_CAVEMAN" -eq 0 ]] && skip_caveman=true

  if [[ "$OS_NAME" == "windows" ]]; then
    WIN_TMP="$(mktemp)"
    if winify_settings "$source" "$WIN_TMP"; then
      source="$WIN_TMP"
      echo "  ℹ Windows: hook commands pinned to an absolute bash.exe + script path"
    else
      echo "  ⚠ Windows: could not resolve bash.exe, leaving hook commands as-is."
      echo "    They will not run if Claude Code spawns hooks through cmd.exe."
    fi
  fi

  if [[ ! -f "$target" ]]; then
    cp "$source" "$target"
    echo "  ✓ settings.json created"
    return
  fi

  # Symlink guard: resolve before writing so `mv` doesn't destroy the symlink.
  if [[ -L "$target" ]]; then
    local resolved
    resolved="$(readlink -f "$target" 2>/dev/null || python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$target")"
    echo "  ℹ settings.json is a symlink → $resolved (editing the real file)"
    target="$resolved"
  fi

  local backup_suffix
  backup_suffix="$(date +%s).$$"

  if jq -s --argjson skipCaveman "$skip_caveman" --arg modelProfile "$MODEL_PROFILE" '
    .[0] as $ours | .[1] as $theirs |
    ($ours * $theirs)
    | .hooks = $ours.hooks
    | .env = (($theirs.env // {}) * ($ours.env // {}))
    | .enabledPlugins = (($theirs.enabledPlugins // {}) * ($ours.enabledPlugins // {}))
    | .extraKnownMarketplaces = (($theirs.extraKnownMarketplaces // {}) * ($ours.extraKnownMarketplaces // {}))
    | .model //= $ours.model
    | .effortLevel //= $ours.effortLevel
    | .advisorModel //= $ours.advisorModel
    | .statusLine //= $ours.statusLine
    | if $skipCaveman then
        del(.enabledPlugins["caveman@caveman"]) | del(.extraKnownMarketplaces.caveman)
      else . end
    | if $modelProfile == "sonnet" then
        .model = "sonnet" | .effortLevel = "high"
      else . end
  ' "$source" "$target" > "$target.tmp" 2>/dev/null; then
    # Canonicalize both via jq -S for stable comparison (jq's `*` operator
    # is not output-byte-stable across runs; sorted-keys form is).
    if diff -q <(jq -S . "$target" 2>/dev/null) <(jq -S . "$target.tmp" 2>/dev/null) >/dev/null 2>&1; then
      rm -f "$target.tmp"
      echo "  ✓ settings.json already up to date"
    else
      cp "$target" "$target.bak.$backup_suffix"
      mv "$target.tmp" "$target"
      if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
        echo "  ✓ settings.json merged (sonnet/high forced by --sonnet; permissions preserved)"
      else
        echo "  ✓ settings.json merged (your model/effortLevel/permissions preserved if set)"
      fi
    fi
  else
    rm -f "$target.tmp"
    cp "$target" "$target.bak.$backup_suffix"
    echo "  ⚠ settings.json jq merge failed — wrote ours, your file is at $target.bak.<ts>"
    cp "$source" "$target"
  fi
}

# ── 5. Copy hooks, commands, rules, bin (per-file backup on conflict) ──
echo "→ Copying hooks, commands, rules, bin (backups for changed files)..."
mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/commands" "$HOME/.claude/rules" "$HOME/.claude/bin"
for src in "$REPO_DIR/hooks/"*; do
  [[ -f "$src" ]] && cp_with_backup "$src" "$HOME/.claude/hooks/$(basename "$src")"
done
for src in "$REPO_DIR/commands/"*; do
  [[ -f "$src" ]] && cp_with_backup "$src" "$HOME/.claude/commands/$(basename "$src")"
done
for src in "$REPO_DIR/rules/"*.md; do
  [[ -f "$src" ]] || continue
  cp_with_backup "$src" "$HOME/.claude/rules/$(basename "$src")"
done
if [[ -d "$REPO_DIR/bin" ]]; then
  for src in "$REPO_DIR/bin/"*; do
    [[ -f "$src" ]] && cp_with_backup "$src" "$HOME/.claude/bin/$(basename "$src")"
  done
fi
chmod +x "$HOME/.claude/hooks/"* "$HOME/.claude/bin/"*.mjs 2>/dev/null || true

# ── 6. Statusline ──
echo "→ Installing statusline..."
cp_with_backup "$REPO_DIR/statusline/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
chmod +x "$HOME/.claude/statusline-command.sh"

# ── 7. CLAUDE.md (prepend in <!--cct--> markers, idempotent on re-run) ──
echo "→ Injecting CLAUDE.md framework block..."
inject_claude_md

# ── 8. settings.json (deep jq merge — preserves user customs) ──
echo "→ Merging settings.json..."
merge_settings_json

# ── 9. Shell wrapper for headroom ──
SHELL_INSTALLED=""
if [[ "$INSTALL_SHELL_WRAPPER" -eq 1 ]]; then
  echo "→ Adding shell wrapper for headroom..."

  # Detect user's actual shell (login shell or $SHELL) and install ONLY for that
  # one. Idempotent: re-running won't re-append. Creates the rc file if missing —
  # a fresh-macOS user with no ~/.zshrc still gets the wrapper.
  USER_SHELL="$(basename "${SHELL:-/bin/zsh}")"
  case "$USER_SHELL" in
    fish)
      rc="$HOME/.config/fish/config.fish"
      mkdir -p "$(dirname "$rc")"; touch "$rc"
      if grep -q 'command headroom wrap claude \$argv' "$rc" 2>/dev/null; then
        perl -0pi -e 's/command headroom wrap claude \$argv/command headroom wrap claude -- \$argv/g' "$rc"
      fi
      if ! grep -q 'headroom wrap claude' "$rc" 2>/dev/null; then
        cat >> "$rc" << 'FISHEOF'

# CBM + Headroom binaries live in ~/.local/bin
if not contains $HOME/.local/bin $PATH
    set -gx PATH $HOME/.local/bin $PATH
end

# Headroom wraps Claude Code for API-layer token compression
function claude
    command headroom wrap claude -- $argv
end
FISHEOF
      fi
      SHELL_INSTALLED="fish ($rc)"
      ;;
    zsh)
      rc="$HOME/.zshrc"
      touch "$rc"
      if grep -q 'command headroom wrap claude "\$@"' "$rc" 2>/dev/null; then
        perl -0pi -e 's/command headroom wrap claude "\$@"/command headroom wrap claude -- "\$@"/g' "$rc"
      fi
      if ! grep -q 'headroom wrap claude' "$rc" 2>/dev/null; then
        cat >> "$rc" << 'ZSHEOF'

# CBM + Headroom binaries live in ~/.local/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac

# Headroom wraps Claude Code for API-layer token compression
claude() { command headroom wrap claude -- "$@"; }
ZSHEOF
      fi
      SHELL_INSTALLED="zsh ($rc)"
      ;;
    bash)
      rc="$HOME/.bashrc"
      touch "$rc"
      if grep -q 'command headroom wrap claude "\$@"' "$rc" 2>/dev/null; then
        perl -0pi -e 's/command headroom wrap claude "\$@"/command headroom wrap claude -- "\$@"/g' "$rc"
      fi
      if ! grep -q 'headroom wrap claude' "$rc" 2>/dev/null; then
        cat >> "$rc" << 'BASHEOF'

# CBM + Headroom binaries live in ~/.local/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac

# Headroom wraps Claude Code for API-layer token compression
claude() { command headroom wrap claude -- "$@"; }
BASHEOF
      fi
      SHELL_INSTALLED="bash ($rc)"
      ;;
    *)
      echo "  ⚠ Unrecognised shell '$USER_SHELL'. Add this to your shell rc manually:"
      echo "      claude() { command headroom wrap claude -- \"\$@\"; }"
      ;;
  esac
  [[ -n "$SHELL_INSTALLED" ]] && echo "  ✓ Shell wrapper installed: $SHELL_INSTALLED"
else
  echo "→ Skipping shell wrapper for headroom (--no-shell-wrapper)"
  echo "  Manual launch stays available: headroom wrap claude -- <claude args>"
fi

# ── 10. Validate ──
echo "→ Validating installation..."
if "$REPO_DIR/install.sh" --check >/dev/null 2>&1; then
  echo "  ✓ All hooks, command plugin refs, and bin scripts resolve"
else
  echo "  ⚠ ./install.sh --check reported issues — re-run for details"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "What was installed:"
report_component() { # report_component <status> <label> <remedy>
  if [[ "$1" == "ok" ]]; then echo "  ✓ $2"; else echo "  ✗ $2 — not installed. $3"; fi
}
report_component "$STATUS_HEADROOM" "Headroom (API-layer compression)" \
  "Run: pip install --user 'headroom-ai[all]'"
report_component "$STATUS_RTK" "RTK (shell-command compression, independent of Headroom)" \
  "See https://github.com/rtk-ai/rtk"
report_component "$STATUS_CBM" "codebase-memory-mcp (knowledge graph for code)" \
  "See https://github.com/DeusData/codebase-memory-mcp/releases"
echo "  ✓ context-mode plugin (output virtualization)"
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "  ✓ Caveman plugin (compressed Claude output)"
else
  echo "  - Caveman plugin skipped (--no-caveman)"
fi
echo "  ✓ All enforcement hooks from repo hooks/"
echo "  ✓ All slash commands from repo commands/"
echo "  ✓ Private agent definitions left untouched in ~/.claude/agents/"
echo "  ✓ Stack rules dir created at ~/.claude/rules/ (empty by design — drop your own per rules/README.md)"
echo "  ✓ bin/ helper scripts (sync-copilot, sync-runner-tools)"
echo "  ✓ Custom statusline"
if [[ "$MODEL_PROFILE" == "sonnet" ]]; then
  echo "  ✓ Optimized settings.json (sonnet/high profile)"
else
  echo "  ✓ Optimized settings.json (opus/xhigh power profile)"
fi
if [[ -n "$SHELL_INSTALLED" ]]; then
  echo "  ✓ Shell wrapper: $SHELL_INSTALLED"
else
  echo "  - Shell wrapper skipped; run manually with: headroom wrap claude -- <claude args>"
fi
echo ""
echo "Next steps:"
echo "  1. Restart your shell: exec \$SHELL"
if [[ "$INSTALL_SHELL_WRAPPER" -eq 1 ]]; then
  echo "  2. Run 'claude' — it now auto-wraps through Headroom"
else
  echo "  2. Run 'headroom wrap claude -- <claude args>' when you want API-layer compression"
fi
echo "  3. In a project, CBM will prompt to index on first use"
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "  4. Run '/caveman' to activate compressed output mode"
else
  echo "  4. Caveman skipped; re-run './install.sh' without --no-caveman to add it"
fi
echo "  5. Re-run './install.sh --check' anytime to validate config"
echo ""
echo "Repos:"
echo "  Headroom:  https://github.com/headroomlabs-ai/headroom"
echo "  CBM:       https://github.com/DeusData/codebase-memory-mcp"
echo "  ctx-mode:  https://github.com/mksglu/context-mode"
echo "  Caveman:   https://github.com/JuliusBrussee/caveman"
echo "  RTK:       https://github.com/rtk-ai/rtk"
