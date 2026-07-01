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
  --opus               Use `model: opus` and `effortLevel: xhigh` instead of the Sonnet/xhigh default.
  -h, --help           Show this help.

Examples:
  ./install.sh
  ./install.sh --no-shell-wrapper
  ./install.sh --no-caveman --opus
  ./install.sh --check --no-caveman --opus
EOF
}

CHECK_ONLY=0
INSTALL_CAVEMAN=1
INSTALL_SHELL_WRAPPER=1
MODEL_PROFILE="sonnet"

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
    --opus)
      MODEL_PROFILE="opus"
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

  if [[ "$MODEL_PROFILE" == "opus" ]]; then
    filter="$filter | .model = \"opus\" | .effortLevel = \"xhigh\""
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

  if [[ $fail -eq 0 ]]; then
    echo "OK: all hooks and command plugin refs resolve"
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
if [[ "$MODEL_PROFILE" == "opus" ]]; then
  echo "Model profile: opus/xhigh (--opus)"
else
  echo "Model profile: sonnet/xhigh"
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
  echo "   Fedora: sudo dnf install -y$missing"
  echo "   macOS:  brew install$missing"
  echo "   Debian: sudo apt-get install -y$missing"
  echo "   Re-run install.sh once they are on PATH."
  exit 1
fi

prepare_settings_source

# ── 1. Install Headroom (includes RTK) ──
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
  "$HR_CMD" install --user "headroom-ai[all]" 2>/dev/null \
    || "$HR_CMD" install "headroom-ai[all]" 2>/dev/null \
    || echo "  ⚠ pip install failed. Run manually: $HR_CMD install --user 'headroom-ai[all]'"
else
  echo "  ⚠ pip / pip3 not found — install Python 3 + pip, then run: pip install --user 'headroom-ai[all]'"
fi

# ── 2. Install codebase-memory-mcp ──
# Releases ship as <name>-<os>-<arch>.tar.gz. We download, VERIFY the SHA-256
# against a pinned value, extract the binary, and drop it in ~/.local/bin
# (caller is expected to have ~/.local/bin on PATH).
#
# SECURITY: we pin to a specific tagged release (never `latest`) and verify the
# tarball checksum before extracting/executing. This prevents a compromised or
# retagged upstream release from silently shipping attacker code onto your box.
#
# To bump: pick a release tag at
#   https://github.com/DeusData/codebase-memory-mcp/releases
# then record its per-asset sha256 below. Get a hash with:
#   curl -fsSL <asset-url> | sha256sum          # Linux
#   curl -fsSL <asset-url> | shasum -a 256      # macOS
CBM_VERSION="v0.0.0"   # TODO: pin to a real release tag before shipping
# Expected sha256 of codebase-memory-mcp-<os>-<arch>.tar.gz per target.
# (case lookup, not `declare -A`, so this stays portable to macOS bash 3.2.)
cbm_expected_sha256() {
  case "$1" in
    darwin-arm64) echo "REPLACE_WITH_REAL_SHA256" ;;
    darwin-amd64) echo "REPLACE_WITH_REAL_SHA256" ;;
    linux-arm64)  echo "REPLACE_WITH_REAL_SHA256" ;;
    linux-amd64)  echo "REPLACE_WITH_REAL_SHA256" ;;
    *) echo "" ;;
  esac
}
echo "→ Installing codebase-memory-mcp ($CBM_VERSION)..."
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

# Portable sha256 helper: sha256sum (Linux) or `shasum -a 256` (macOS).
cbm_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1; fi
}

if [[ -n "$CBM_OS" && -n "$CBM_ARCH" ]]; then
  CBM_KEY="${CBM_OS}-${CBM_ARCH}"
  CBM_EXPECTED="$(cbm_expected_sha256 "$CBM_KEY")"
  CBM_URL="https://github.com/DeusData/codebase-memory-mcp/releases/download/${CBM_VERSION}/codebase-memory-mcp-${CBM_KEY}.tar.gz"
  if [[ -z "$CBM_EXPECTED" || "$CBM_EXPECTED" == REPLACE_WITH_REAL_SHA256 ]]; then
    echo "  ⚠ No pinned sha256 for $CBM_KEY ($CBM_VERSION) — refusing to install unverified binary."
    echo "    Fill in cbm_expected_sha256() for '$CBM_KEY' in install.sh, then re-run."
  else
    mkdir -p "$HOME/.local/bin"
    CBM_TMP="$(mktemp -d)"
    if curl -fsSL "$CBM_URL" -o "$CBM_TMP/cbm.tar.gz"; then
      CBM_ACTUAL="$(cbm_sha256 "$CBM_TMP/cbm.tar.gz" || echo "")"
      if [[ -z "$CBM_ACTUAL" ]]; then
        echo "  ⚠ Cannot compute sha256 (no sha256sum/shasum) — refusing unverified install."
      elif [[ "$CBM_ACTUAL" != "$CBM_EXPECTED" ]]; then
        echo "  ✗ CBM checksum MISMATCH — refusing to install."
        echo "    expected: $CBM_EXPECTED"
        echo "    actual:   $CBM_ACTUAL"
        echo "    Either the pin is stale or the download was tampered with. Aborting CBM install."
      else
        tar -xzf "$CBM_TMP/cbm.tar.gz" -C "$CBM_TMP"
        if [[ -f "$CBM_TMP/codebase-memory-mcp" ]]; then
          mv "$CBM_TMP/codebase-memory-mcp" "$HOME/.local/bin/codebase-memory-mcp"
          chmod +x "$HOME/.local/bin/codebase-memory-mcp"
          "$HOME/.local/bin/codebase-memory-mcp" setup claude-code 2>/dev/null || true
          echo "  ✓ CBM $CBM_VERSION installed at ~/.local/bin/codebase-memory-mcp (sha256 verified)"
        else
          echo "  ⚠ CBM tarball extracted but binary not found — open an issue at the repo"
        fi
      fi
    else
      echo "  ⚠ CBM download failed ($CBM_URL). Skip and run manually later."
    fi
    rm -rf "$CBM_TMP"
  fi
fi

# ── 3. Install Claude Code plugins (context-mode + optional caveman) ──
# Plugin install (not raw `mcp add`) so context-mode tools resolve under
# `mcp__plugin_context-mode_context-mode__*` — the namespace the context-mode
# hooks expect. Raw `mcp add` produces `mcp__context-mode__*` instead. Caveman
# stays enabled by default for the power-user profile, but --no-caveman keeps
# private style choices out of the merged settings.
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
# to remove Caveman or force the opus/xhigh model profile.
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
    | if $modelProfile == "opus" then
        .model = "opus" | .effortLevel = "xhigh"
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
      if [[ "$MODEL_PROFILE" == "opus" ]]; then
        echo "  ✓ settings.json merged (opus/xhigh forced by --opus; permissions preserved)"
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

# ── 5. Copy hooks, commands, rules (per-file backup on conflict) ──
echo "→ Copying hooks, commands, rules (backups for changed files)..."
mkdir -p "$HOME/.claude/hooks" "$HOME/.claude/commands" "$HOME/.claude/rules"
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
chmod +x "$HOME/.claude/hooks/"* 2>/dev/null || true

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
echo "  ✓ Headroom (API-layer compression, bundles RTK)"
echo "  ✓ codebase-memory-mcp (knowledge graph for code)"
echo "  ✓ context-mode plugin (output virtualization)"
if [[ "$INSTALL_CAVEMAN" -eq 1 ]]; then
  echo "  ✓ Caveman plugin (compressed Claude output)"
else
  echo "  - Caveman plugin skipped (--no-caveman)"
fi
echo "  ✓ All enforcement hooks from repo hooks/"
echo "  ✓ Stack rules dir created at ~/.claude/rules/ (empty by design — drop your own per rules/README.md)"
echo "  ✓ Custom statusline"
if [[ "$MODEL_PROFILE" == "opus" ]]; then
  echo "  ✓ Optimized settings.json (opus/xhigh power profile)"
else
  echo "  ✓ Optimized settings.json (sonnet/xhigh profile)"
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
