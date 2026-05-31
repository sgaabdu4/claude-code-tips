#!/bin/bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Claude Code Token Optimization Stack installer

Usage:
  ./install.sh [options]

Power-user default:
  Installs Headroom + RTK, CBM, context-mode, Caveman, hooks, commands,
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

cleanup_tmp() {
  [[ -n "${SETTINGS_TMP:-}" ]] && rm -f "$SETTINGS_TMP"
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

  # 1. JSON syntax
  if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not installed (required by hooks + check mode)"; fail=1
  else
    prepare_settings_source
    if ! jq empty "$SETTINGS_SOURCE" 2>/dev/null; then
      echo "FAIL: settings/settings.json is not valid JSON"; fail=1
    fi
  fi

  # 2. Every hook command path in settings resolves to a file in repo hooks/
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      hook_path="${cmd//\~/$HOME}"
      hook_path="${hook_path%% *}"
      [[ "$hook_path" == "$HOME/.claude/hooks/"* ]] || continue
      hook_name="${hook_path##*/}"
      if [[ ! -f "$REPO_DIR/hooks/$hook_name" ]]; then
        echo "FAIL: settings.json references hook '$hook_name' but $REPO_DIR/hooks/$hook_name missing"; fail=1
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
    echo "OK: all hooks, command plugin refs, and bin/ scripts resolve"
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
  echo "   macOS:             brew install$missing"
  echo "   Debian/Ubuntu:     sudo apt-get install -y$missing"
  echo "   RHEL/Rocky/Fedora: sudo dnf install -y epel-release && sudo dnf install -y$missing   # jq lives in EPEL"
  echo "   Re-run install.sh once they are on PATH."
  exit 1
fi

prepare_settings_source

# ── 1. Install Headroom (includes RTK) ──
# Headroom needs Python >=3.10 (PyPI metadata: requires_python ">=3.10").
# Distros whose default `python3` is older break here: RHEL/Rocky 8 ship 3.6.8,
# so bare `pip3` targets the wrong interpreter and the install fails. Fix: pick
# the newest interpreter >=3.10, build an isolated venv from it, and symlink the
# `headroom` entrypoint onto PATH (~/.local/bin). The venv also sidesteps PEP 668
# "externally-managed-environment" errors on Homebrew/Debian without --user.
# Idempotent: an existing venv is reused. Extras = [all] for full feature parity
# with the article's stack (memory/voice/ml/image/integrations all included).
# NOTE: [all] is HEAVY — it pulls sentence-transformers + torch + a full CUDA
# stack (multi-GB); the venv isolates it from the system. Want a lean, torch-free
# install instead? Set HR_EXTRAS="proxy,mcp,code" (proxy is the mandatory wrap/
# proxy core). RTK self-installs (musl static binary) on the first `headroom wrap`.
echo "→ Installing Headroom..."
HR_EXTRAS="all"
HR_VENV="$HOME/.local/share/headroom-venv"

# find_py310: echo the first python on PATH whose version is >= 3.10, else fail.
find_py310() {
  local cand
  for cand in python3.13 python3.12 python3.11 python3.10 python3 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 10) else 1)' 2>/dev/null; then
      command -v "$cand"; return 0
    fi
  done
  return 1
}

HR_PY="$(find_py310 || true)"
if [[ -z "$HR_PY" ]]; then
  echo "  ⚠ No Python >=3.10 found — Headroom requires it. Install one, then re-run:"
  echo "    RHEL/Rocky 8:  sudo dnf install -y python3.11"
  echo "    Debian/Ubuntu: sudo apt-get install -y python3.11-venv"
  echo "    macOS:         brew install python@3.12"
else
  [[ -x "$HR_VENV/bin/python" ]] || "$HR_PY" -m venv "$HR_VENV" 2>/dev/null \
    || echo "  ⚠ venv creation failed ($HR_PY). Need the venv module: dnf/apt install the python3.x-venv package."
  if [[ -x "$HR_VENV/bin/pip" ]]; then
    "$HR_VENV/bin/pip" install -q -U pip >/dev/null 2>&1 || true
    if "$HR_VENV/bin/pip" install -q "headroom-ai[$HR_EXTRAS]" 2>/dev/null; then
      mkdir -p "$HOME/.local/bin"
      ln -sf "$HR_VENV/bin/headroom" "$HOME/.local/bin/headroom"
      echo "  ✓ Headroom installed ($("$HR_VENV/bin/python" -V 2>&1), extras: $HR_EXTRAS) → ~/.local/bin/headroom"
    else
      echo "  ⚠ Headroom install failed. Retry verbosely: $HR_VENV/bin/pip install 'headroom-ai[$HR_EXTRAS]'"
    fi
  fi
fi

# ── 2. Install codebase-memory-mcp ──
# Releases ship as <name>-<os>-<arch>.tar.gz. We download, extract the binary,
# and drop it in ~/.local/bin (caller is expected to have ~/.local/bin on PATH).
echo "→ Installing codebase-memory-mcp..."
CBM_OS=""
CBM_ARCH=""
case "$(uname)" in
  Darwin) CBM_OS="darwin" ;;
  Linux)  CBM_OS="linux" ;;
  *) echo "  ⚠ Unsupported OS: $(uname). Skipping CBM install."; CBM_OS="" ;;
esac
case "$(uname -m)" in
  arm64|aarch64)  CBM_ARCH="arm64" ;;
  x86_64|amd64)   CBM_ARCH="amd64" ;;
  *) echo "  ⚠ Unsupported arch: $(uname -m). Skipping CBM install."; CBM_ARCH="" ;;
esac
if [[ -n "$CBM_OS" && -n "$CBM_ARCH" ]]; then
  CBM_URL="https://github.com/DeusData/codebase-memory-mcp/releases/latest/download/codebase-memory-mcp-${CBM_OS}-${CBM_ARCH}.tar.gz"
  mkdir -p "$HOME/.local/bin"
  CBM_TMP="$(mktemp -d)"
  if curl -fsSL "$CBM_URL" -o "$CBM_TMP/cbm.tar.gz"; then
    tar -xzf "$CBM_TMP/cbm.tar.gz" -C "$CBM_TMP"
    if [[ -f "$CBM_TMP/codebase-memory-mcp" ]]; then
      mv "$CBM_TMP/codebase-memory-mcp" "$HOME/.local/bin/codebase-memory-mcp"
      chmod +x "$HOME/.local/bin/codebase-memory-mcp"
      "$HOME/.local/bin/codebase-memory-mcp" setup claude-code 2>/dev/null || true
      echo "  ✓ CBM installed at ~/.local/bin/codebase-memory-mcp"
    else
      echo "  ⚠ CBM tarball extracted but binary not found — open an issue at the repo"
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
  claude plugin marketplace add mksglu/context-mode 2>/dev/null \
    || echo "  (run 'claude plugin marketplace add mksglu/context-mode' manually if this failed)"
  claude plugin install context-mode@context-mode 2>/dev/null \
    || echo "  (run 'claude plugin install context-mode@context-mode' manually if this failed)"
  if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
    claude plugin marketplace add JuliusBrussee/caveman 2>/dev/null \
      || echo "  (run 'claude plugin marketplace add JuliusBrussee/caveman' manually if this failed)"
    claude plugin install caveman@caveman 2>/dev/null \
      || echo "  (run 'claude plugin install caveman@caveman' manually if this failed)"
  fi
fi

# ── 3b. RHEL/Rocky: compile context-mode's better-sqlite3 native binding ──
# context-mode bundles better-sqlite3 (its FTS5 store). On RHEL 8 / Rocky 8
# the default gcc (8.5) can't build it (-std=c++20 unsupported) and the
# plugin installs via bun, which skips the native compile — so the MCP shows
# "✗ Failed to connect" until the binding is built with a newer toolchain.
# Best-effort, non-fatal fixup: runs only on RHEL-family hosts, only when the
# binding fails to load, and never aborts the install (see README Rocky notes).
if [[ -f /etc/redhat-release ]] && command -v node >/dev/null 2>&1; then
  BSQ="$(ls -d "$HOME"/.claude/plugins/cache/context-mode/context-mode/*/node_modules/better-sqlite3 2>/dev/null | sort -V | tail -1)"
  bsq_loads() { node -e "const D=require('$1'); new D(':memory:').close()" >/dev/null 2>&1; }
  if [[ -n "$BSQ" ]] && ! bsq_loads "$BSQ"; then
    echo "→ context-mode: building better-sqlite3 native binding (RHEL/Rocky)..."
    # C++20 compiler: gcc-toolset static-links newer libstdc++ → runs on base glibc
    GTS=""
    for v in 14 13 12; do
      [[ -f "/opt/rh/gcc-toolset-$v/enable" ]] && { GTS="/opt/rh/gcc-toolset-$v/enable"; break; }
    done
    # node-gyp 10 needs Python >= 3.8 (rejects the 3.6 default)
    GYP_PY=""
    for p in python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
      command -v "$p" >/dev/null 2>&1 && { GYP_PY="$(command -v "$p")"; break; }
    done
    if [[ -z "$GTS" || -z "$GYP_PY" ]]; then
      echo "  ⚠ Need gcc-toolset (C++20) + Python>=3.8. Install, then re-run ./install.sh:"
      echo "    sudo dnf install -y gcc-toolset-13 python3.11"
    else
      (
        set +e
        . "$GTS"
        export PYTHON="$GYP_PY"
        # bun skips node-gyp configure, so the build/ Makefile may be absent
        [[ -f "$BSQ/build/Makefile" ]] || npx -y node-gyp@latest configure --directory="$BSQ" >/dev/null 2>&1
        # Two-pass make: node-gyp deletes the .deps dir on the sqlite3 codegen
        # ACTION, so pass 1 fails at compile; recreate the dirs, then pass 2
        # compiles + links better_sqlite3.node.
        make -C "$BSQ/build" >/dev/null 2>&1
        mkdir -p "$BSQ/build/Release/.deps/Release/obj.target/sqlite3/gen/sqlite3" \
                 "$BSQ/build/Release/.deps/Release/obj.target/better_sqlite3/src"
        make -C "$BSQ/build" >/dev/null 2>&1
      ) || true
      if bsq_loads "$BSQ"; then
        echo "  ✓ better-sqlite3 built — context-mode MCP will connect."
      else
        echo "  ⚠ Auto-build failed. See 'RHEL / Rocky Linux 8 notes' in README.md for the manual recipe."
      fi
    fi
  fi
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
merge_settings_json() {
  local target="$HOME/.claude/settings.json"
  local source="$SETTINGS_SOURCE"
  local skip_caveman=false
  [[ "$INSTALL_CAVEMAN" -eq 0 ]] && skip_caveman=true

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

# CBM + Headroom binaries live in ~/.local/bin; rtk lives in ~/.headroom/bin
if not contains $HOME/.local/bin $PATH
    set -gx PATH $HOME/.local/bin $PATH
end
if not contains $HOME/.headroom/bin $PATH
    set -gx PATH $HOME/.headroom/bin $PATH
end

# Headroom wraps Claude Code for API-layer token compression (telemetry off)
set -gx HEADROOM_TELEMETRY off
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

# CBM + Headroom binaries live in ~/.local/bin; rtk lives in ~/.headroom/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
case ":$PATH:" in *":$HOME/.headroom/bin:"*) ;; *) export PATH="$HOME/.headroom/bin:$PATH";; esac

# Headroom wraps Claude Code for API-layer token compression (telemetry off)
export HEADROOM_TELEMETRY=off
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

# CBM + Headroom binaries live in ~/.local/bin; rtk lives in ~/.headroom/bin
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH";; esac
case ":$PATH:" in *":$HOME/.headroom/bin:"*) ;; *) export PATH="$HOME/.headroom/bin:$PATH";; esac

# Headroom wraps Claude Code for API-layer token compression (telemetry off)
export HEADROOM_TELEMETRY=off
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
echo "  ✓ Headroom (API-layer compression, bundles RTK)"
echo "  ✓ codebase-memory-mcp (knowledge graph for code)"
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
echo "  Headroom:  https://github.com/chopratejas/headroom"
echo "  CBM:       https://github.com/DeusData/codebase-memory-mcp"
echo "  ctx-mode:  https://github.com/mksglu/context-mode"
echo "  Caveman:   https://github.com/JuliusBrussee/caveman"
echo "  RTK:       https://github.com/rtk-ai/rtk (bundled in Headroom)"
