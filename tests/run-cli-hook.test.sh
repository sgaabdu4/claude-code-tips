#!/bin/bash
# Sandboxed tests for hooks/run-cli-hook + install.sh --check.
#
# Everything runs against a throwaway $HOME under mktemp -d. Nothing here reads
# or writes the real ~/.claude, and install.sh is only ever invoked with
# --check (which is side-effect free — it mktemps at most).
#
# Run: ./tests/run-cli-hook.test.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIM="$REPO_DIR/hooks/run-cli-hook"
SANDBOX="$(mktemp -d)"
REAL_HOME="$HOME"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0
ok()   { echo "  ok   - $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL - $1"; echo "         $2"; fail=$((fail + 1)); }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# Guard: a bug in this file must never let a test touch the real home.
[[ "$SANDBOX" == "$REAL_HOME" ]] && { echo "sandbox == real HOME, aborting"; exit 1; }

# A stub that proves it ran: echoes its args and whatever arrived on stdin.
make_stub() { # make_stub <dir> <name>
  mkdir -p "$1"
  cat > "$1/$2" <<'STUB'
#!/bin/bash
echo "ran:$(basename "$0") args:$* stdin:$(cat)"
STUB
  chmod +x "$1/$2"
}

# Minimal PATH = what a GUI-launched Claude Code actually hands a hook. No
# ~/.local/bin, no ~/.headroom/bin, no homebrew.
BARE_PATH="/usr/bin:/bin"

echo "=== run-cli-hook ==="

# 1. The reported bug: rtk in ~/.headroom/bin, absent from PATH. Before the fix
#    settings.json ran bare `rtk` here and Claude Code raised
#    "rtk: No such file or directory (os error 2)".
make_stub "$SANDBOX/.headroom/bin" rtk
out=$(echo '{"tool_name":"Bash"}' | env -i HOME="$SANDBOX" PATH="$BARE_PATH" "$SHIM" rtk hook claude 2>&1)
check "resolves rtk from ~/.headroom/bin when PATH lacks it" \
      'ran:rtk args:hook claude stdin:{"tool_name":"Bash"}' "$out"

# 2. Same for pip --user / npm -g style installs.
make_stub "$SANDBOX/.local/bin" context-mode
out=$(echo 'payload' | env -i HOME="$SANDBOX" PATH="$BARE_PATH" "$SHIM" context-mode hook claude-code pretooluse 2>&1)
check "resolves context-mode from ~/.local/bin" \
      'ran:context-mode args:hook claude-code pretooluse stdin:payload' "$out"

# 3. Missing binary must not block the tool call: silent, exit 0.
out=$(echo 'x' | env -i HOME="$SANDBOX" PATH="$BARE_PATH" "$SHIM" definitely-not-installed hook 2>&1)
rc=$?
check "missing binary exits 0" "0" "$rc"
check "missing binary stays silent" "" "$out"

# 4. PATH wins when the user has wired things up already.
make_stub "$SANDBOX/onpath" rtk
out=$(echo '' | env -i HOME="$SANDBOX" PATH="$SANDBOX/onpath:$BARE_PATH" "$SHIM" rtk gain 2>&1)
check "PATH takes precedence over probe dirs" 'ran:rtk args:gain stdin:' "$out"

# 5. Escape hatch for installs in a dir we do not know about.
make_stub "$SANDBOX/custom" rtk
out=$(echo '' | env -i HOME="$SANDBOX" PATH="$BARE_PATH" CCT_RTK_BIN="$SANDBOX/custom/rtk" "$SHIM" rtk x 2>&1)
check "CCT_RTK_BIN override wins" 'ran:rtk args:x stdin:' "$out"

# 6. Override var name derivation for a hyphenated binary.
out=$(echo '' | env -i HOME="$SANDBOX" PATH="$BARE_PATH" CCT_CONTEXT_MODE_BIN="$SANDBOX/custom/rtk" "$SHIM" context-mode y 2>&1)
check "CCT_CONTEXT_MODE_BIN maps from context-mode" 'ran:rtk args:y stdin:' "$out"

# 7. --which, used by install.sh --check.
out=$(env -i HOME="$SANDBOX" PATH="$BARE_PATH" "$SHIM" --which rtk 2>&1)
check "--which prints resolved path" "$SANDBOX/.headroom/bin/rtk" "$out"
env -i HOME="$SANDBOX" PATH="$BARE_PATH" "$SHIM" --which definitely-not-installed >/dev/null 2>&1
check "--which exits 1 when unresolvable" "1" "$?"

# 8. No args must not explode.
env -i HOME="$SANDBOX" PATH="$BARE_PATH" "$SHIM" </dev/null >/dev/null 2>&1
check "no args exits 0" "0" "$?"

echo
echo "=== settings/settings.json ==="

SETTINGS="$REPO_DIR/settings/settings.json"
jq empty "$SETTINGS" 2>/dev/null
check "valid JSON" "0" "$?"

# Regression guard for issue #2: no hook may invoke a CLI by bare name again.
bare=$(jq -r '[.. | objects | select(.command? != null) | .command] | .[]' "$SETTINGS" \
  | awk '{print $1}' \
  | grep -vE '^(~|/|bash|sh)' || true)
check "no hook invokes a bare CLI name" "" "$bare"

# Every shim call must name a binary.
empty_shim=$(jq -r '[.. | objects | select(.command? != null) | .command] | .[]' "$SETTINGS" \
  | grep 'run-cli-hook' | awk 'NF < 2 {print}' || true)
check "every run-cli-hook call passes a binary" "" "$empty_shim"

# Models are current-generation.
check "model pinned to opus 5" "claude-opus-5" "$(jq -r '.model' "$SETTINGS")"
check "subagent model pinned to sonnet 5" "claude-sonnet-5" "$(jq -r '.env.CLAUDE_CODE_SUBAGENT_MODEL' "$SETTINGS")"
check "default opus keeps 1h cache suffix" "claude-opus-5[1m]" "$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL' "$SETTINGS")"

# Keys the user deliberately set must survive this change.
for k in skipDangerousModePermissionPrompt skipAutoPermissionPrompt agentPushNotifEnabled; do
  check "preserved key $k" "true" "$(jq -r ".$k" "$SETTINGS")"
done
check "preserved permissions.defaultMode" "auto" "$(jq -r '.permissions.defaultMode' "$SETTINGS")"

echo
echo "=== install.sh --check ==="

# Every hook file referenced by settings must exist in the repo.
missing=$(jq -r '[.. | objects | select(.command? != null) | .command] | .[]' "$SETTINGS" \
  | awk '{print $1}' | grep '^~/.claude/hooks/' | sed 's|^~/.claude/hooks/||' \
  | while read -r h; do [[ -f "$REPO_DIR/hooks/$h" ]] || echo "$h"; done)
check "all referenced hooks exist in repo" "" "$missing"

# --check must PASS in a sandbox where the CLIs are present.
out=$(env HOME="$SANDBOX" "$REPO_DIR/install.sh" --check 2>&1); rc=$?
check "--check exits 0 when CLIs resolve" "0" "$rc"
if grep -q '^WARN' <<<"$out"; then
  bad "--check is quiet when CLIs resolve" "got: $(grep '^WARN' <<<"$out" | head -2)"
else
  ok "--check is quiet when CLIs resolve"
fi

# The regression that shipped: a hook whose CLI cannot be found anywhere used
# to produce a clean OK. Assert against a repo copy pointed at a CLI that
# genuinely does not exist, so the result does not depend on what happens to be
# installed on the host running the tests.
EMPTY="$SANDBOX/empty-home"; mkdir -p "$EMPTY"
REPO_COPY="$SANDBOX/repo"; mkdir -p "$REPO_COPY"
cp -R "$REPO_DIR/settings" "$REPO_DIR/hooks" "$REPO_DIR/commands" "$REPO_DIR/bin" "$REPO_COPY/"
cp "$REPO_DIR/install.sh" "$REPO_COPY/install.sh"
jq 'walk(if type == "object" and (.command? | type) == "string"
         then .command |= sub("run-cli-hook rtk"; "run-cli-hook cct-absent-cli")
         else . end)' "$SETTINGS" > "$REPO_COPY/settings/settings.json"

out=$(env HOME="$EMPTY" "$REPO_COPY/install.sh" --check 2>&1); rc=$?
check "--check still exits 0 for an absent CLI (warn, not fail)" "0" "$rc"
if grep -q "needs 'cct-absent-cli'" <<<"$out"; then
  ok "--check warns about an unresolvable hook CLI"
else
  bad "--check warns about an unresolvable hook CLI" "no warning in output: $out"
fi
if grep -q 'CCT_CCT_ABSENT_CLI_BIN' <<<"$out"; then
  ok "--check names the override env var in its remedy"
else
  bad "--check names the override env var in its remedy" "no override hint in: $out"
fi
if grep -q '1 warning(s)' <<<"$out"; then
  ok "--check summary reports the warning count"
else
  bad "--check summary reports the warning count" "summary did not mention warnings: $(tail -1 <<<"$out")"
fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
