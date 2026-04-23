# How I Cut Claude Code Token Usage by 90%+ With 5 Tools, Custom Hooks, and Enforcement

> **TL;DR:** I stack 5 layers to cut Claude Code token usage by 90%+: (1) **Codebase Memory MCP** — knowledge graph replaces file reads for code exploration (99% savings), (2) **context-mode** — sandboxes large outputs and returns only summaries (98% savings), (3) **RTK** — compresses CLI output in-place (60-90% savings), (4) **Headroom** — API proxy that compresses the entire prompt before it leaves your machine (47-92% savings), (5) **Caveman** — makes Claude's own responses terse (50-75% savings). Custom hooks *enforce* these tools so Claude can't bypass them. Sessions go from ~30 min to 3+ hours. One-click install script at the bottom.

---

Early on with Claude Code, I burned through context in 20-30 minutes and hit rate limits constantly. After a few iterations I landed on a layered stack that extends sessions to 3+ hours and cuts token cost hard.

📦 **Companion repo:** [`github.com/sgaabdu4/claude-code-tips`](https://github.com/sgaabdu4/claude-code-tips) — every config, hook, and script below.

## The Problem

Claude Code is hungry. `cargo test` (262 tests) = 4,823 tokens. `git diff HEAD~1` = 21,500 tokens. A 500-line file Read fills the window fast. Autocompact trips early, history vanishes, sessions die, budget burns.

## The Solution: 5 Layers, Each at a Different Point in the Pipeline

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

Each layer catches what the previous missed. Different points, no overlap.

---

## Layer 1: Codebase Memory MCP (99% Token Savings on Code Exploration)

**Repo:** [github.com/DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)

**What it does:** Indexes your entire codebase into a persistent knowledge graph using tree-sitter AST parsing across 66 languages. Instead of reading files to answer "who calls this function?" or "show me the architecture," Claude queries the graph and gets structured answers in ~50 tokens instead of reading 50 files (~400K tokens).

**Real numbers:** Five structural queries consumed ~3,400 tokens via CBM versus ~412,000 tokens via file-by-file grep exploration, a **99.2% reduction**.

### How I enforce it

I don't just *tell* Claude to use CBM first. I *block* it from falling back to file reads without using CBM.

**The gate pattern:** Two hooks work together. A PreToolUse hook blocks `Grep`/`Glob`/`Read` on source files. A PostToolUse hook touches a marker file whenever a `codebase-memory-mcp` tool runs. The gate allows `Read` for 120 seconds after a CBM call (so Claude can read-then-edit), and always allows non-code files (configs, docs, JSON).

**`~/.claude/hooks/cbm-code-discovery-gate`** (PreToolUse) — [full file in repo](https://github.com/sgaabdu4/claude-code-tips/blob/main/hooks/cbm-code-discovery-gate). Core logic:

```bash
case "$TOOL" in
  Read)
    FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
    # Allow configs, docs, tests, settings
    if [[ "$FP" =~ \.(json|yaml|yml|md|toml|lock|txt|env|sh)$ ]] \
      || [[ "$FP" =~ (\.claude|CLAUDE\.md|settings|hooks/|/test/|_test\.) ]]; then exit 0; fi
    # Allow Read if CBM was used in last 120s
    if [ -f "$MARKER" ]; then
      AGE=$(( $(date +%s) - $(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER") ))
      [ "$AGE" -lt 120 ] && exit 0
    fi
    echo "BLOCKED Read on source without a recent codebase-memory-mcp call." >&2
    exit 2 ;;
esac
```

`Grep` and `Glob` branches follow the same pattern. Two companion hooks ([repo](https://github.com/sgaabdu4/claude-code-tips/tree/main/hooks)):

- **`cbm-mcp-marker`** (PostToolUse) — touches `/tmp/cbm-mcp-used-$PPID` when a CBM tool fires, giving the gate its 120s unlock window.
- **`cbm-session-reminder`** (SessionStart, matches `resume`/`clear`/`compact`) — re-injects the CBM protocol so Claude doesn't forget mid-session.

**Key insight:** Claude *will* fall back to `Read`/`Grep` if you only *suggest* CBM. Suggestion isn't enforcement; blocking is.

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

One hook per lifecycle event (`PreToolUse`/`PostToolUse`/`PreCompact`/`SessionStart`), each calling `context-mode hook claude-code <event>`. See [full `settings.json`](https://github.com/sgaabdu4/claude-code-tips/blob/main/settings/settings.json).

Tip: add a sibling PreToolUse hook on your test runner (`npm test`, `pytest`, `go test ./...`) that warns Claude to use `ctx_batch_execute` — whole suites produce thousands of lines.

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

**vs context-mode:** no overlap. context-mode sandboxes large outputs (>20 lines). RTK compresses small-to-medium shell output in-place (`git status`, `npm install`, quick test results). RTK ships bundled inside Headroom (next layer).

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

### Setup — one shell function

```bash
# Bash/Zsh (Fish: wrap in `function claude ... end`)
claude() { command headroom wrap claude "$@"; }
```

Starts a local proxy, sets `ANTHROPIC_BASE_URL`, launches Claude. `--resume`, `-p "query"`, all args pass through. RTK auto-registers.

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

Caveman installs via the Claude Code third-party plugin marketplace — enable in `settings.json` under `enabledPlugins` + `extraKnownMarketplaces` pointing at `JuliusBrussee/caveman`. Hooks auto-activate on `SessionStart` + `UserPromptSubmit`. Full snippet in the [companion `settings.json`](https://github.com/sgaabdu4/claude-code-tips/blob/main/settings/settings.json).

---

## Bonus hook: bash-ban-raw-tools

Sibling to the CBM gate. Problem: when Claude runs `cat file.py` or `grep "pattern" src/` via Bash, raw output bypasses every compression hook — `Read`/`Grep` are throttled by MCP + context-mode, but Bash goes straight to context.

Fix: block the raw commands and force Claude through the optimised tools. [Full file](https://github.com/sgaabdu4/claude-code-tips/blob/main/hooks/bash-ban-raw-tools). Core:

```bash
case "$FIRST" in
  cat|head|tail|find|grep|rg|wc) banned=1 ;;
  rtk) exit 0 ;;                     # RTK wrappers pass through
esac

# Truncation pipes still flood context before the trim
if echo "$CMD" | grep -qE '\|\s*(tail|head)\b'; then
  echo "BLOCKED pipe truncation." >&2; exit 2
fi
```

Escape hatch: `touch /tmp/bash-raw-unlock` (auto-expires 10 min).

---

## The Complete settings.json

[Full file in repo](https://github.com/sgaabdu4/claude-code-tips/blob/main/settings/settings.json). Top-level shape:

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
  "permissions": { "defaultMode": "auto" },
  "model": "claude-opus-4-6[1M]",
  "effortLevel": "medium",
  "advisorModel": "opus",
  "statusLine": { "type": "command", "command": "bash ~/.claude/statusline-command.sh", "refreshInterval": 1000 },
  "enabledPlugins": { "caveman@caveman": true },
  "hooks": {
    "PreToolUse":  [ /* Bash → context-mode + bash-ban-raw-tools; Grep|Glob|Read → cbm-code-discovery-gate */ ],
    "PostToolUse": [ /* context-mode + cbm-mcp-marker */ ],
    "PreCompact":  [ /* context-mode */ ],
    "SessionStart":[ /* context-mode + cbm-session-reminder on resume|clear|compact */ ]
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

Your CLAUDE.md is instructions for *in-session* behavior. Don't document external tools (Headroom, RTK) here — they operate outside the session and Claude can't see them. Only instruct on tools Claude actively calls.

[Full file in repo](https://github.com/sgaabdu4/claude-code-tips/blob/main/CLAUDE.md.example). Core sections:

```markdown
## Principles
DRY/KISS/YAGNI/SSOT. No guess — read code first. Fail→change approach. Ask before destructive.

## Skill gates
Dart/Flutter → `building-flutter-apps` FIRST.
React/Next → `vercel-react-best-practices` FIRST.
Appwrite → `appwrite-backend` FIRST.

## Ripple check — NON-NEGOTIABLE
Any add/change/remove: grep symbol + CBM `trace_path` for ALL usages. Update every call site.

## Tools — Quickref
| Want | Tool |
|---|---|
| Find def | `search_graph` |
| A→B flow | `trace_path` |
| Arch | `get_architecture` |
| Read snippet | `get_code_snippet` |
| Run cmd | `ctx_execute` / `ctx_batch_execute` |
| Read log/big file | `ctx_execute_file` |
| Fetch URL | `ctx_fetch_and_index` → `ctx_search` |

## Banned Bash
`cat`/`head`/`tail`/`grep`/`find`.
```

Full file also covers: Session start protocol (MANDATORY `index_status`), TDD, per-stack skill gates, subagent delegation policy, and reply style rules.

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

## Custom Status Line

Colour-coded dashboard — ctx/5h/7d bars, branch, model, time. Point `statusLine.command` at [`statusline-command.sh`](https://github.com/sgaabdu4/claude-code-tips/blob/main/statusline/statusline-command.sh).

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

Layers compound — each catches what the previous missed.

## Install

```bash
git clone https://github.com/sgaabdu4/claude-code-tips.git
cd claude-code-tips && chmod +x install.sh && ./install.sh
```

Installs Headroom (bundles RTK), codebase-memory-mcp, context-mode, Caveman plugin, all hooks, statusline, `settings.json`, shell wrappers (fish/bash/zsh). Backs up your existing `~/.claude/settings.json` first. Tune `model` / `effortLevel` / `advisorModel` after.

## Closer

Don't *tell* Claude to be efficient — *enforce* it. Hooks that block wasteful patterns beat 1000 words of CLAUDE.md. Claude follows the path of least resistance. Make the efficient path the only path.
