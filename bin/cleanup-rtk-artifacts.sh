#!/bin/bash
# Find (and optionally remove) rtk leftovers from a Headroom install.
#
# headroomlabs-ai/headroom#2677 dropped the vendored rtk without a cleanup
# path, so a dangling `rtk` symlink can survive on PATH. It still shows up in a
# $PATH listing, but execve() on it returns ENOENT — which surfaces inside a
# Claude Code hook as `rtk: No such file or directory (os error 2)`.
#
# Usage:
#   bin/cleanup-rtk-artifacts.sh            report only (default)
#   bin/cleanup-rtk-artifacts.sh --apply    delete the dead symlinks it found

set -uo pipefail

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
found=0

echo "→ Scanning for dangling 'rtk' symlinks..."
scan_dirs=$(printf '%s\n' "${PATH//:/$'\n'}" \
              "$HOME/.headroom/bin" "$HOME/.local/bin" \
              /opt/homebrew/bin /usr/local/bin "$HOME/.cargo/bin" | sort -u)
while IFS= read -r dir; do
  [[ -n "$dir" && -d "$dir" ]] || continue
  target="$dir/rtk"
  # -L true, -e false == symlink whose target is gone.
  if [[ -L "$target" && ! -e "$target" ]]; then
    found=$((found + 1))
    echo "  dangling: $target → $(readlink "$target" 2>/dev/null)"
    if [[ $APPLY -eq 1 ]]; then
      rm -f "$target" && echo "    removed"
    fi
  fi
done <<<"$scan_dirs"

[[ $found -eq 0 ]] && echo "  none found"

# Headroom generated this wrapper and its internal `command -v rtk` is what
# broke; if rtk no longer resolves at all the file is dead weight.
echo "→ Checking for an orphaned Headroom hook wrapper..."
wrapper="$HOME/.claude/hooks/rtk-rewrite.sh"
if [[ -f "$wrapper" ]]; then
  if "$REPO_DIR/hooks/run-cli-hook" --which rtk >/dev/null 2>&1; then
    echo "  $wrapper exists and rtk still resolves — leaving it alone"
  else
    echo "  orphaned: $wrapper (rtk does not resolve anywhere)"
    if [[ $APPLY -eq 1 ]]; then
      rm -f "$wrapper" && echo "    removed"
    fi
  fi
else
  echo "  none found"
fi

echo "→ Checking ~/.claude/settings.json for hooks calling rtk directly..."
settings="$HOME/.claude/settings.json"
if [[ -f "$settings" ]] && command -v jq >/dev/null 2>&1; then
  stale=$(jq -r '[.. | objects | select(.command? != null) | .command]
                 | .[] | select(test("(^|/)rtk( |$)"))
                 | select(test("run-cli-hook") | not)' "$settings" 2>/dev/null)
  if [[ -n "$stale" ]]; then
    echo "  these bypass the shim and will break again if rtk moves:"
    printf '    %s\n' $stale
    echo "  fix: re-run ./install.sh to route them through hooks/run-cli-hook"
  else
    echo "  none found"
  fi
else
  echo "  skipped (no settings.json, or jq missing)"
fi

if [[ $APPLY -eq 0 ]]; then
  echo ""
  echo "Report only. Re-run with --apply to delete the dead symlinks above."
fi
