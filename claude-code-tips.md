# How I Cut Claude Code Token Usage by 90%+ With 5 Tools, Custom Hooks, and Enforcement

> **TL;DR:** I stack 5 layers to cut Claude Code token usage by 90%+: (1) **Codebase Memory MCP** — knowledge graph replaces file reads for code exploration (99% savings), (2) **context-mode** — sandboxes large outputs and returns only summaries (98% savings), (3) **RTK** — compresses CLI output in-place (60-90% savings), (4) **Headroom** — API proxy that compresses the entire prompt before it leaves your machine (47-92% savings), (5) **Caveman** — makes Claude's own responses terse (50-75% savings). Custom hooks *enforce* these tools so Claude can't bypass them. Sessions go from ~30 min to 3+ hours. One-click install script at the bottom.

---

I've been using Claude Code for a bit now. Early on, I burned through context windows in 20-30 minutes and hit rate limits constantly. After multiple iterations, I built a layered optimisation stack that extends sessions to 3+ hours and cuts token costs dramatically.

Here's my complete setup: every config file, every hook, and the reasoning behind each layer. There's also a one-click install script at the end.

---

## The Problem

Claude Code is powerful, but it's hungry. Every `git log`, every file read, every test run dumps raw output into your context window. A single `cargo test` with 262 passing tests? 4,823 tokens. A `git diff HEAD~1`? 21,500 tokens. Read a 500-line file? That's your context window filling up fast.

The result: autocompact triggers early, you lose conversation history, sessions end prematurely, and your monthly token budget evaporates.

## The Solution: 4 Layers, Each Operating at a Different Point

```
┌───────────────────────────────────────────────────┐
│               YOUR PROMPT / QUERY                 │
└─────────────────────┬─────────────────────────────┘
                      │
         ┌────────────▼────────────┐
         │   Layer 1: CBM          │  "Don't read the file at all"
         │   (Knowledge Graph)     │  99% savings on structural queries
         └────────────┬────────────┘
                      │
         ┌────────────▼────────────┐
         │   Layer 2: context-mode │  "Run it, but keep output sandboxed"
         │  (Output Virtualisation)│  98% savings on large outputs
         └────────────┬────────────┘
                      │
         ┌────────────▼────────────┐
         │   Layer 3: RTK          │  "Compress what enters context"
         │   (Shell Compression)   │  60-90% savings on CLI output
         └────────────┬────────────┘
                      │
         ┌────────────▼────────────┐
         │   Layer 4: Headroom     │  "Compress everything at the API"
         │   (API-Layer Proxy)     │  47-92% on all remaining tokens
         └────────────┴────────────┘
                      │
              ┌───────▼───────┐
              │    Caveman    │  "Claude talks less too"
              │ (Output Style)│  50-75% on Claude's own responses
              └───────┬───────┘
                      │
                      ▼
              Anthropic API
```

Each layer catches what the previous one missed. No redundancy, they operate at fundamentally different points in the pipeline.

---

## Layer 1: Codebase Memory MCP (99% Token Savings on Code Exploration)

**Repo:** [github.com/DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)

**What it does:** Indexes your entire codebase into a persistent knowledge graph using tree-sitter AST parsing across 66 languages. Instead of reading files to answer "who calls this function?" or "show me the architecture," Claude queries the graph and gets structured answers in ~50 tokens instead of reading 50 files (~400K tokens).

**Real numbers:** Five structural queries consumed ~3,400 tokens via CBM versus ~412,000 tokens via file-by-file grep exploration, a **99.2% reduction**.

### How I enforce it

I don't just *tell* Claude to use CBM first. I *block* it from falling back to file reads without using CBM.

**The gate pattern:** Two hooks work together. A PreToolUse hook blocks `Grep`/`Glob`/`Read` on source files. A PostToolUse hook touches a marker file whenever a `codebase-memory-mcp` tool runs. The gate allows `Read` for 120 seconds after a CBM call (so Claude can read-then-edit), and always allows non-code files (configs, docs, JSON).

**`~/.claude/hooks/cbm-code-discovery-gate`** (PreToolUse):

```bash
#!/bin/bash
# Blocks Grep/Glob/Read on source files so codebase-memory-mcp is used first.
# PostToolUse sibling hook updates /tmp/cbm-mcp-used-$PPID on every MCP call —
# Read unlocks for 120s after a fresh codebase-memory-mcp discovery call.
# Escape hatch: touch /tmp/cbm-unlock-$PPID (one-session override).
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
    # Allow non-code files through (configs, docs, etc.)
    if [[ "$GLOB" =~ \.(json|yaml|yml|md|toml|lock|txt|env)$ ]] \
      || [[ "$TYPE" =~ ^(json|yaml|md|toml|txt)$ ]] \
      || [[ "$PATH_Q" =~ (\.claude|settings|CLAUDE\.md|/tmp/|/var/) ]]; then
      exit 0
    fi
    echo "BLOCKED Grep on source code. Use codebase-memory-mcp: search_graph(query='...') or search_code(pattern='...'). Override: touch $UNLOCK." >&2
    exit 2
    ;;
  Glob)
    PATTERN=$(echo "$INPUT" | jq -r '.tool_input.pattern // ""')
    if [[ "$PATTERN" =~ \.(dart|ts|tsx|js|jsx|py|go|rs|java|kt|swift)$ ]] \
      || [[ "$PATTERN" =~ ^(lib|src|app)/ ]]; then
      echo "BLOCKED Glob on source tree. Use codebase-memory-mcp: search_graph(name_pattern='.*name.*') or get_architecture(). Override: touch $UNLOCK." >&2
      exit 2
    fi
    ;;
  Read)
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
    # Allow configs, docs, test files, settings
    if [[ "$FP" =~ \.(json|yaml|yml|md|toml|lock|txt|env|sh)$ ]] \
      || [[ "$FP" =~ (\.claude|CLAUDE\.md|settings|hooks/|/test/|_test\.) ]]; then
      exit 0
    fi
    # Allow if CBM was used recently (120s window)
    if [ -f "$MARKER" ]; then
      AGE=$(( $(date +%s) - $(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER" 2>/dev/null || echo 0) ))
      [ "$AGE" -lt 120 ] && exit 0
    fi
    echo "BLOCKED Read on source file without a recent codebase-memory-mcp call. Run search_graph/get_code_snippet first, THEN Read the file you need to Edit. Override: touch $UNLOCK." >&2
    exit 2
    ;;
esac
exit 0
```

**`~/.claude/hooks/cbm-mcp-marker`** (PostToolUse companion):

```bash
#!/bin/bash
# Touch the marker whenever a codebase-memory-mcp tool runs.
set -euo pipefail
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [[ "$TOOL" == mcp__codebase-memory-mcp__* ]]; then
  touch /tmp/cbm-mcp-used-$PPID
fi
exit 0
```

**`~/.claude/hooks/cbm-session-reminder`** (SessionStart - fires on start, resume, clear, compact):

```bash
#!/bin/bash
# Remind agent to use codebase-memory-mcp tools at session boundaries.
cat << 'REMINDER'
CRITICAL - Code Discovery Protocol:
1. ALWAYS use codebase-memory-mcp tools FIRST for ANY code exploration:
   - search_graph(name_pattern/label/qn_pattern) to find functions/classes/routes
   - trace_path(function_name, mode=calls|data_flow|cross_service) for call chains
   - get_code_snippet(qualified_name) to read source (NOT Read/cat)
   - query_graph(query) for complex Cypher patterns
   - get_architecture(aspects) for project structure
   - search_code(pattern) for text search (graph-augmented grep)
2. Fall back to Grep/Glob/Read ONLY for text content, config values, non-code files.
3. If a project is not indexed yet, run index_repository FIRST.
REMINDER
```

**The key insight:** Claude *will* fall back to `Read` and `Grep` if you only *suggest* it use CBM. You need enforcement. The gate blocks source-file reads unless CBM was called in the last 120 seconds. Non-code files (configs, docs, JSON) pass through freely. The session reminder re-injects the protocol after every `/clear` or `/compact` so Claude doesn't forget mid-session.

---

## Layer 2: context-mode (98% Token Savings on Large Outputs)

**Repo:** [github.com/mksglu/context-mode](https://github.com/mksglu/context-mode)

**What it does:** A context virtualization layer. Instead of letting tool outputs flow raw into the conversation context, it intercepts them, runs them in a sandboxed subprocess, indexes the full output into a local BM25 knowledge base, and returns only a compact summary. The full output remains searchable on demand.

**Real numbers:**

| Operation | Raw | With context-mode | Savings |
|---|---|---|---|
| Playwright DOM snapshot | 56.2 KB | 299 B | 99% |
| GitHub Issues (20) | 58.9 KB | 1.1 KB | 98% |
| Git log (153 commits) | 11.6 KB | 107 B | 99% |
| Full session | 315 KB | 5.4 KB | 98% |

Sessions extend from ~30 minutes to ~3 hours on the same 200K context window.

### Key tools it provides

- **`ctx_batch_execute`**: Run multiple commands in one call, auto-index all output, search with multiple queries. Returns summaries, not raw data. One call replaces 30+ individual tool calls.
- **`ctx_search`**: Follow-up BM25 search over anything previously indexed in the session.
- **`ctx_execute` / `ctx_execute_file`**: Run code/analysis in the sandbox. Only the printed summary enters context.
- **`ctx_fetch_and_index`**: Fetch a URL, index it, return a ~3KB preview. Full content stays searchable.
- **`ctx_stats`**: Show token savings analytics for the current session.

### How I integrate it

context-mode hooks into every lifecycle event:

```json
{
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        { "type": "command", "command": "context-mode hook claude-code pretooluse" }
      ]
    }
  ],
  "PostToolUse": [
    {
      "hooks": [
        { "type": "command", "command": "context-mode hook claude-code posttooluse" }
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
    }
  ]
}
```

### Nudge test runners toward the sandbox

Whole-suite test runs produce thousands of lines. A small PreToolUse hook can warn Claude to route them through `ctx_batch_execute` instead of raw Bash — same template as `bash-ban-raw-tools`, matched on your test command (`npm test`, `pytest`, `go test ./...`, etc.) without a scoping flag.

---

## Layer 3: RTK - Rust Token Killer (60-90% on Shell Output)

**Repo:** [github.com/rtk-ai/rtk](https://github.com/rtk-ai/rtk)

**What it does:** A Rust binary that intercepts CLI command output and compresses it before it enters the context window. Strips boilerplate, groups similar items, truncates long output, deduplicates repeated entries. Single binary, <10ms overhead, no network calls.

**Real numbers:**

| Command | Standard | RTK | Savings |
|---|---|---|---|
| `cargo test` (262 tests) | 4,823 | 11 | 99% |
| `git diff HEAD~1` | 21,500 | 1,259 | 94% |
| `npm test` | 25,000 | 2,500 | 90% |
| `git add/commit/push` | 1,600 | 120 | 92% |

### Why keep it alongside context-mode?

Different targets:
- **context-mode**: large outputs (>20 lines) that get fully sandboxed and indexed
- **RTK**: small-to-medium shell output - `git status`, `npm install`, quick test results, compressed in-place before entering context

They don't conflict. RTK is managed by Headroom (see Layer 4), which bundles it internally and auto-registers the hook.

---

## Layer 4: Headroom (47-92% on Everything That Reaches the API)

**Repo:** [github.com/chopratejas/headroom](https://github.com/chopratejas/headroom)

**What it does:** Sits between Claude Code and the Anthropic API. Compresses the *entire prompt* (conversation history, system prompts, tool outputs, everything) before it leaves your machine. Uses:
- **CodeCompressor**: AST-aware compression for Python, JS, Go, Rust, Java, C++
- **SmartCrusher**: JSON array/object compression
- **Kompress-base**: HuggingFace ML model trained on agentic traces
- **CacheAligner**: Stabilizes prompt prefixes so Anthropic's KV cache actually hits

**The unique value:** Layers 1-3 reduce what *enters* the context window. Headroom compresses what *leaves* it, including conversation history, system prompts, and CLAUDE.md instructions that no other tool touches.

**Reported savings:**

| Workload | Savings |
|---|---|
| Code search (100 results) | 92% |
| SRE incident debugging | 92% |
| GitHub issue triage | 73% |
| Codebase exploration | 47% |
| Log needle-in-haystack | 87% |

### Setup - One Shell Function

Every shell gets the same wrapper. When you type `claude`, it transparently launches through Headroom:

**Fish** (`~/.config/fish/config.fish`):
```fish
# Headroom wraps Claude Code for API-layer token compression
function claude
    command headroom wrap claude $argv
end
```

**Bash** (`~/.bashrc`) and **Zsh** (`~/.zshrc`):
```bash
# Headroom wraps Claude Code for API-layer token compression
claude() { command headroom wrap claude "$@"; }
```

`headroom wrap claude` starts a local proxy, sets `ANTHROPIC_BASE_URL`, and launches Claude Code. All args pass through `claude --resume`, `claude -p "query"`, etc. all work. Headroom bundles RTK internally and auto-registers the RTK hook in your session.

---

## Layer 5: Caveman Plugin (50-75% on Claude's Own Output)

**Repo:** [github.com/JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)

This one is often overlooked: **Claude's own verbose responses count against your context window**. Every "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..." is wasted tokens.

Caveman is a Claude Code plugin that makes Claude respond in compressed style. Drops articles, filler words, hedging, pleasantries. All technical substance stays, only fluff dies.

**Before:**
> "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by a race condition in the authentication middleware where the token expiry check uses a strict less-than comparison instead of less-than-or-equal."

**After:**
> "Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:"

### It's more than just a speaking style

Caveman ships with automatic hooks and sub-skills:

- **`/caveman:compress`**: Compresses your CLAUDE.md and memory files *permanently* into caveman format. Saves tokens on every single future session start since CLAUDE.md is loaded into context every time. This is a multiplicative saving.
- **`/caveman:caveman-commit`**: Compressed commit message generator. Subject ≤50 chars, body only when "why" isn't obvious.
- **`/caveman:caveman-review`**: Compressed code review comments. Each comment is one line: location, problem, fix.
- **`/caveman-help`**: Quick reference for all modes and commands.

**Intensity levels:** `lite` (gentle compression), `full` (classic caveman, default), `ultra` (maximum compression).

### Installation

Caveman uses the Claude Code third-party plugin marketplace system:

```json
{
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
  }
}
```

The `extraKnownMarketplaces` field tells Claude Code to fetch the plugin from a GitHub repository rather than the official marketplace. Caveman's hooks auto-activate via `SessionStart` and `UserPromptSubmit`. It tracks mode switches and writes the active mode to a flag file so it persists through the session.

---

## The Enforcement Layer: bash-ban-raw-tools

The most impactful hook isn't about compression, it's about preventing Claude from wasting tokens on raw tool usage.

**The problem:** When Claude runs `cat file.py` or `grep "pattern" src/` via Bash, the raw output bypasses ALL compression hooks. The built-in `Read` and `Grep` tools are subject to MCP output limits and context-mode interception. But Bash? Straight into context, uncompressed.

**The fix:** Block those commands and force Claude through the optimized tools:

```bash
#!/bin/bash
# PreToolUse Bash gate: block cat/head/tail/find/grep/rg/wc invocations.
# Forces use of Read/Grep/Glob tools (which are subject to compression hooks).
# Escape hatch: touch /tmp/bash-raw-unlock (expires after 10 min).
set -euo pipefail

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL" = "Bash" ] || exit 0

UNLOCK=/tmp/bash-raw-unlock
# Unlock expires after 10 min (prevents silent permanent bypass).
check_unlock() {
  local f=$1
  [ -f "$f" ] || return 1
  local mtime
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
  local age=$(( $(date +%s) - mtime ))
  if [ "$age" -lt 600 ]; then return 0; fi
  rm -f "$f"; return 1
}
check_unlock "$UNLOCK" && exit 0
check_unlock "/tmp/bash-raw-unlock-$PPID" && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
TRIMMED=$(echo "$CMD" | sed -E 's/^[[:space:]]*//')
FIRST=$(echo "$TRIMMED" | awk '{print $1}')

banned=0
case "$FIRST" in
  cat|head|tail|find|grep|rg|wc) banned=1 ;;
  rtk) exit 0 ;;  # RTK wrappers pass through
esac

# Catch truncation pipes (cat file.py | head -20)
if echo "$CMD" | grep -qE '\|\s*(tail|head)\b' && echo "$FIRST" | grep -qE '^(cat|grep|rg|find)$'; then
  cat >&2 <<EOF
BLOCKED: '| tail'/'| head' pipeline. Output truncation not allowed — raw output still floods context before trim.

REPLACE WITH ctx_batch_execute:
  commands: [{"label": "your label", "command": "your command"}]
  queries:  ["what you're looking for"]
EOF
  exit 2
fi

[ "$banned" -eq 0 ] && exit 0

case "$FIRST" in
  cat|head|tail) echo "BLOCKED '$FIRST'. Use the Read tool." >&2 ;;
  find) echo "BLOCKED 'find'. Use the Glob tool." >&2 ;;
  grep|rg) echo "BLOCKED '$FIRST'. Use the Grep tool." >&2 ;;
  wc) echo "BLOCKED 'wc'. Use Read (line count visible) or rtk wc." >&2 ;;
esac
exit 2
```

**The escape hatch:** `touch /tmp/bash-raw-unlock`, auto-expires after 10 minutes. Because sometimes you actually do need raw Bash.

---

## The Complete settings.json

Here's every setting, explained:

```json
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
  "model": "claude-opus-4-6[1M]",
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
```

### What each env var does

| Variable | Value | Purpose |
|---|---|---|
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `70` | Trigger compaction at 70% instead of default. Aggressive, but with 4 compression layers you rarely hit it. |
| `BASH_MAX_OUTPUT_LENGTH` | `10000` | Hard cap on Bash output tokens. Safety net - context-mode and RTK handle most compression, this catches the rest. |
| `MAX_MCP_OUTPUT_TOKENS` | `10000` | Hard cap on MCP tool output tokens. Same safety net for MCP responses. |
| `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` | `1` | Disables background tasks that consume tokens silently. |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | `1` | Enables experimental agent teams feature - spawn multiple specialized agents that coordinate via shared task lists. |
| `ENABLE_PROMPT_CACHING_1H` | `1` | Extends prompt cache TTL to 1 hour (default is 5 minutes). Massive cost savings on long sessions. |

### Other settings explained

| Setting | Value | Purpose |
|---|---|---|
| `effortLevel` | `medium` | Claude thinks less per response = fewer output tokens. Increase to `high` for complex architecture decisions. |
| `advisorModel` | `opus` | Uses the strongest model for the built-in advisor tool (second opinion on complex decisions). |
| `defaultMode` | `auto` | Claude auto-accepts tool calls that match permission rules. Reduces back-and-forth. |
| `skipDangerousModePermissionPrompt` | `true` | Skip the confirmation prompt when using `--dangerously-skip-permissions`. |
| `skipAutoPermissionPrompt` | `true` | Skip the confirmation prompt when using auto mode. |

---

## The CLAUDE.md That Makes It Work

Your CLAUDE.md is instructions for *in-session* behavior. Don't document external tools (Headroom, RTK) here, they operate outside the session and Claude can't see them. Only instruct on tools Claude actively calls:

```markdown
# Rules

## Principles
DRY/KISS/YAGNI/SSOT. No guess—read code first. Search existing before add. Min scope.
Verify: lint+typecheck+tests. Fail→change approach. Ask before destructive.

## Skill gates
Dart/Flutter → `building-flutter-apps` FIRST.
React/Next → `vercel-react-best-practices` FIRST.
Appwrite → `appwrite-backend` FIRST.

## Ripple check - NON-NEGOTIABLE
Any add/change/remove: MUST grep symbol + CBM `trace_path` to find ALL usages.
Update every call site in same change - never partial.

## TDD
Red/green/refactor. Tests first. Happy+fail+edge every change.

## Tools
CBM (code 99% save) + context-mode (shell sandbox).

### Session start (MANDATORY)
`index_status` → unindexed? `index_repository`. Indexed? `detect_changes`. Before any code work.

### Code → CBM graph, never grep→read→grep
`search_graph`/`search_code` find. `trace_path` connect. `get_architecture` structure.
`get_code_snippet` read. `query_graph` Cypher. Fallback `Grep`/`Glob`/`Read` only if unindexed.

### Shell/run/read → context-mode sandbox
`ctx_batch_execute` >1 cmd or >20 lines. `ctx_execute` run code. `ctx_execute_file` large file.
`ctx_fetch_and_index` URL (not `WebFetch`). `ctx_search` follow-up + recall. `ctx_index` store.
No `| tail`/`| head`.

### Files
`Read` + `Edit`/`Write`. `Read` before `Edit`. No `ctx_execute` for writes.

### Docs
`tvly` CLI first (skills: `tavily-cli`, `tavily-dynamic-search`). Never trust training for
signatures/versions/READMEs. `tvly search` topic; `tvly extract <url>` known URL;
`ctx_fetch_and_index` fallback.

### Banned Bash
`cat`/`head`/`tail`/`grep`/`find`.

### Quickref
| Want | Tool |
|---|---|
| Find def | `search_graph` |
| A→B flow | `trace_path` |
| Arch | `get_architecture` |
| Read snippet | `get_code_snippet` |
| Run cmd | `ctx_execute` / `ctx_batch_execute` |
| Read log/big file | `ctx_execute_file` |
| Fetch URL | `ctx_fetch_and_index` → `ctx_search` |
| Recall prior | `ctx_search` |

## Subagents
Default: delegate. Main thread coordinate only.
Parallel: independent → one msg, multiple `Agent`.

## Replies
Min tokens. Answer first. Bullets > prose. No filler/preamble/recap/summary.
```

### Per-language rule files

I also use `.claude/rules/` for stack-specific enforcement. Loaded via `@` import from `CLAUDE.md`. One file per stack — skill to invoke first, numbered self-check of the handful of footguns Claude repeatedly trips on. Build the list from actual failures you've seen.

**`~/.claude/rules/flutter.md`:**
```md
# Flutter/Dart gate — NON-NEGOTIABLE
Invoke `building-flutter-apps` skill FIRST. No skip.
Self-check:
1. `if (!ref.mounted) return;` after every `await` in notifier
2. `if (!context.mounted) return;` after every `await` in widget/State
3. No `_buildXxx()` — extract widget classes
4. No hardcoded strings — `*Strings` constants
5. `ref.watch` in build, `ref.read` in callbacks only
6. Riverpod 3.x codegen: `FooNotifier` → `fooProvider`
7. No `shrinkWrap: true` on ListView/GridView
```

**`~/.claude/rules/react.md`:**
```md
# React/Next.js gate
Invoke `vercel-react-best-practices` skill FIRST.
Self-check:
1. Server Components default. `"use client"` only for interaction
2. Heavy compute → `useMemo` w/ stable deps. Never in `.map()` callbacks
3. No `enum` — `as const` objects
4. Status variants → `Record<Status, Variant>` map, not ternary chains
```

**`~/.claude/rules/appwrite.md`:**
```md
# Appwrite gate
Invoke `appwrite-backend` skill FIRST for ANY Appwrite code.
```

Swap in your own stacks — the point is one skill-gated rule file per framework you actually ship.

---

## The Custom Status Line

A visual dashboard showing context usage, rate limits, git branch, and model, all at a glance. Color-coded progress bars: green < 50% < yellow < 75% < orange < 90% < red.

Wire it in settings.json:
```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh",
    "refreshInterval": 1000
  }
}
```

The script:
```bash
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
```

Output:
```
user in ~/project on  main │ ⬡ o4.6 │ ctx ████░░░░ 48% │ 5h ██░░░░░░ 23% │ 7d █░░░░░░░ 12% │ 09:59
```

---

## Results

| Metric | Before | After |
|--------|--------|-------|
| Session duration | ~30 min | 3+ hours |
| Tokens per code exploration | ~400K | ~3.4K |
| Context at autocompact | 100% (default) | 70% (rarely hit) |
| Shell output tokens | Full | 10-40% of original |
| API tokens sent | Full | 8-53% of original |
| Claude's response verbosity | Full prose | 25-50% of original |

The compound effect is massive. CBM eliminates 99% of code exploration tokens. context-mode sandboxes 98% of large outputs. RTK compresses remaining shell output by 60-90%. Headroom squeezes the final payload by another 47-92% before it hits the API. And Caveman cuts Claude's own output by 50-75%.

---

## One-Click Install

Save this script and run it. It installs all tools, creates all hooks, configures settings.json, and sets up the shell wrapper.

```bash
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
```

Save as `install-claude-optimizer.sh` and run:
```bash
curl -fsSL https://gist.githubusercontent.com/YOUR_USERNAME/YOUR_GIST_ID/raw/install-claude-optimizer.sh | bash
```

Or locally:
```bash
chmod +x install-claude-optimizer.sh && ./install-claude-optimizer.sh
```

> **Note:** The install script backs up your existing `settings.json` before overwriting. Review and adjust settings like `model`, `effortLevel`, and `advisorModel` to match your plan.

---

## The Philosophy

Don't just *tell* Claude to be efficient, *enforce* it. Hooks that block wasteful patterns are worth more than 1000 words of CLAUDE.md instructions. Claude will always find the path of least resistance. Make the efficient path the only path.

Each layer is independent and additive. Start with whichever solves your biggest pain point:
- Burning tokens on code exploration? → [CBM](https://github.com/DeusData/codebase-memory-mcp)
- Sessions too short? → [context-mode](https://github.com/mksglu/context-mode)
- CLI output bloating context? → RTK (bundled in [Headroom](https://github.com/chopratejas/headroom))
- Want to compress everything at the API layer? → [Headroom](https://github.com/chopratejas/headroom)
- Claude too verbose? → [Caveman](https://github.com/JuliusBrussee/caveman)

Stack them all for compound savings that change how you use Claude Code entirely.
