#!/bin/bash
# Tests for hooks/cbm-code-discovery-gate + hooks/cbm-mcp-marker.
#
# Each hook call runs through its own `bash -c` wrapper, the way Claude Code
# spawns hook commands, so $PPID differs on every call. The gate must still
# block only the first call of a session.
#
# Run: ./tests/cbm-hooks.test.sh
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$REPO_DIR/hooks/cbm-code-discovery-gate"
MARKER="$REPO_DIR/hooks/cbm-mcp-marker"
# Unique per run so leftovers in /tmp from earlier runs never match.
RUN="ccttest$$$RANDOM"
trap 'rm -f /tmp/cbm-code-discovery-gate-${RUN}* /tmp/cbm-mcp-used-${RUN}*' EXIT

pass=0
fail=0
ok()   { echo "  ok   - $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL - $1"; echo "         $2"; fail=$((fail + 1)); }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# run_hook <hook> <json>: prints the exit code. Fresh wrapper shell per call.
run_hook() {
  printf '%s' "$2" | bash -c '"$1" >/dev/null 2>&1; echo $?' _ "$1"
}

echo "=== cbm hooks ==="

command -v jq >/dev/null || { echo "  skip - jq not installed"; exit 0; }

# 1. First Read of a session is blocked, the next ones pass.
s1="{\"session_id\":\"${RUN}-a\",\"tool_name\":\"Read\"}"
check "first Read of a session is blocked" 2 "$(run_hook "$GATE" "$s1")"
check "second Read of the same session passes" 0 "$(run_hook "$GATE" "$s1")"
check "third Read of the same session passes" 0 "$(run_hook "$GATE" "$s1")"

# 2. A new session is blocked once again.
s2="{\"session_id\":\"${RUN}-b\",\"tool_name\":\"Read\"}"
check "first Read of another session is blocked" 2 "$(run_hook "$GATE" "$s2")"

# 3. A CBM tool call before any Read disarms the gate for that session.
s3="{\"session_id\":\"${RUN}-c\",\"tool_name\":\"mcp__codebase-memory-mcp__search_graph\"}"
check "marker exits 0" 0 "$(run_hook "$MARKER" "$s3")"
check "Read after a CBM call passes" 0 \
      "$(run_hook "$GATE" "{\"session_id\":\"${RUN}-c\",\"tool_name\":\"Read\"}")"

# 4. A non-CBM tool does not disarm the gate.
s4="{\"session_id\":\"${RUN}-d\",\"tool_name\":\"Bash\"}"
run_hook "$MARKER" "$s4" >/dev/null
check "Read after a non-CBM tool is still blocked" 2 \
      "$(run_hook "$GATE" "{\"session_id\":\"${RUN}-d\",\"tool_name\":\"Read\"}")"

# 5. Path characters in session_id cannot escape /tmp.
s5="{\"session_id\":\"../${RUN}-e\",\"tool_name\":\"Read\"}"
run_hook "$GATE" "$s5" >/dev/null
check "session_id is stripped to a safe file name" "yes" \
      "$([[ -f /tmp/cbm-code-discovery-gate-${RUN}-e ]] && echo yes || echo no)"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
