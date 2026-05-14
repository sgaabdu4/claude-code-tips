# How I Cut Claude Code Token Usage by 90%+ With 5 Tools, Custom Hooks, and Enforcement

> **TL;DR:** Five layers, each ripping tokens out at a different point in the pipeline. (1) **Codebase Memory MCP** trades file reads for a knowledge graph (99% off). (2) **context-mode** sandboxes large outputs and hands back a summary (98% off). (3) **RTK** compresses CLI output in place (60-90% off). (4) **Headroom** is an API proxy that compresses everything before it leaves your machine (47-92% off). (5) **Caveman** makes Claude itself talk less (50-75% off). Hooks *enforce* the stack so Claude can't slip back to the lazy path. My sessions stretched from 30 minutes to 3+ hours. One-click installer at the bottom.

### Cheat sheet: every tip in 60 seconds

- **`/clear` aggressively** + disable unused MCP servers per session
- **Mermaid over prose** for architecture: fewer tokens, native parse
- **CBM** (graph) for code discovery · **context-mode** for large outputs · **RTK** for shell · **Headroom** for API payload · **Caveman** for Claude's own output
- **Two hooks do the heavy lifting:** `bash-ban-raw-tools` (blocks `cat`/`grep`/`find`/…) + `cbm-code-discovery-gate` (blocks `Read`/`Grep` on source until CBM is called)
- **`/caveman:compress`** your CLAUDE.md: multiplicative win, loads every session
- **Per-stack rule files** in `~/.claude/rules/<stack>.md`: skill gate + numbered self-check. Repo ships an empty `rules/` with [`README.md`](https://github.com/sgaabdu4/claude-code-tips/blob/main/rules/README.md). Drop in your own. Mine stay private since they only match my stacks; examples are further down.
- **CLI over MCP** for Tavily/Appwrite: same power, way less context
- **Only 2 MCP servers:** `codebase-memory-mcp` + `context-mode`. Everything else is CLI or hooks
- **PostToolUse reject scanners**: ESLint custom rule · node regex scanner · Dart analyzer plugin · Husky + lint-staged
- **Settings:** `model: claude-opus-4-7`, `effortLevel: xhigh`, `advisorModel: opus`, `ENABLE_PROMPT_CACHING_1H=1`, `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50`, `CLAUDE_CODE_SUBAGENT_MODEL=claude-sonnet-4-6`
- **Multi-model pipeline:** Opus 4.7 plan (or `/ultraplan`) → Opus implement → `/unleash` swarm → cross-vendor review (I use Codex GPT-5.5, any intelligent model works) → same for E2E (Agent Browser dogfood for web, Dart MCP for Flutter)
- **Measure savings** with [Codeburn](https://github.com/getagentseal/codeburn) · dictate with Fluid Voice (Parakeet)

---

Early on with Claude Code, I burned through context in 20-30 minutes and hit rate limits constantly. After a few iterations I landed on a layered stack that extends sessions to 3+ hours and cuts token cost hard.

📦 **Companion repo:** [`github.com/sgaabdu4/claude-code-tips`](https://github.com/sgaabdu4/claude-code-tips) contains every config, hook, and script below.

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

## Quick wins before you touch any hooks

Three zero-effort moves that save tokens today:

- **`/clear` aggressively.** Short focused sessions beat long ones. The longer the session, the more Claude re-reads its own trail. ([Claude Code slash commands](https://code.claude.com/docs/en/claude-code/slash-commands))
- **Disable unused MCP servers per session.** `claude mcp list` → drop anything this task doesn't need. Unused servers burn context silently via tool descriptions. ([`claude mcp` reference](https://code.claude.com/docs/en/claude-code/cli-reference#mcp))
- **Prefer Mermaid over prose for architecture.** A 6-line Mermaid diagram carries the same shape as 3 paragraphs at a fraction of the tokens, and Claude parses it natively.

---

## Layer 1: Codebase Memory MCP (99% Token Savings on Code Exploration)

**Repo:** [github.com/DeusData/codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp)

**What it does:** Indexes your entire codebase into a persistent knowledge graph using tree-sitter AST parsing across 66 languages. Instead of reading files to answer "who calls this function?" or "show me the architecture," Claude queries the graph and gets structured answers in ~50 tokens instead of reading 50 files (~400K tokens).

**Real numbers:** Five structural queries consumed ~3,400 tokens via CBM versus ~412,000 tokens via file-by-file grep exploration, a **99.2% reduction**.

### How I enforce it

I don't just *tell* Claude to use CBM first. I *block* it from falling back to file reads without using CBM.

**The gate pattern:** Two hooks work in tandem. A PreToolUse hook fires on the FIRST `Grep`/`Glob`/`Read`/`Search` of the session and blocks it. A PostToolUse hook touches a marker file the moment any `codebase-memory-mcp` tool runs. Once that marker exists, the gate steps aside for the rest of the session. One CBM call is all it takes.

**`~/.claude/hooks/cbm-code-discovery-gate`** (PreToolUse): a 16-line state machine driven by two PPID-scoped `/tmp` flags. One is the "blocked once" flag (`cbm-code-discovery-gate-$PPID`, written by this hook). The other is the "CBM was used" flag (`cbm-mcp-used-$PPID`, written by the companion `cbm-mcp-marker` hook). First `Grep`/`Glob`/`Read`/`Search` call exits 2 with a CBM nudge and drops the "blocked once" flag. Every call after that exits 0, either because CBM has since run (the "CBM was used" flag exists) or because Claude already saw the block once (the "blocked once" flag exists) and the gate self-disarms so the rest of the session flows. Full source: [`hooks/cbm-code-discovery-gate`](https://github.com/sgaabdu4/claude-code-tips/blob/main/hooks/cbm-code-discovery-gate).

Two companion hooks ([`hooks/`](https://github.com/sgaabdu4/claude-code-tips/tree/main/hooks)):

- **`cbm-mcp-marker`** (PostToolUse): touches `/tmp/cbm-mcp-used-$PPID` when any `mcp__codebase-memory-mcp__*` tool fires. The gate sees it and lets every subsequent file-search through.
- **`cbm-session-reminder`** (SessionStart, matches `startup`/`resume`/`clear`/`compact`): re-injects the CBM protocol so Claude doesn't forget mid-session.

Claude *will* drift back to `Read`/`Grep` the moment you only *suggest* CBM. Suggestion isn't enforcement. Blocking is.

---

## Layer 2: context-mode (98% Token Savings on Large Outputs)

**Repo:** [github.com/mksglu/context-mode](https://github.com/mksglu/context-mode)

**What it does:** A context virtualization layer. Instead of letting tool outputs flow raw into the conversation context, it intercepts them, runs them in a sandboxed subprocess, indexes the full output into a local BM25 knowledge base, and returns only a compact summary. The full output remains searchable on demand.

**Real numbers:**

https://gist.github.com/sgaabdu4/031abf87a6043bedbfb5c408d008482c

Sessions extend from ~30 minutes to ~3 hours on the same 200K context window.

### Key tools it provides

- **`ctx_batch_execute`**: Run multiple commands in one call, auto-index all output, search with multiple queries. Returns summaries, not raw data. One call replaces 30+ individual tool calls.
- **`ctx_search`**: Follow-up BM25 search over anything previously indexed in the session.
- **`ctx_execute` / `ctx_execute_file`**: Run code/analysis in the sandbox. Only the printed summary enters context.
- **`ctx_fetch_and_index`**: Fetch a URL, index it, return a ~3KB preview. Full content stays searchable.
- **`ctx_stats`**: Show token savings analytics for the current session.

### How I integrate it

Install as a plugin so its tools land under `mcp__plugin_context-mode_context-mode__*` (the namespace `/e2e`, `/unleash`, and other slash commands reference):

Install via `claude plugin marketplace add mksglu/context-mode` then `claude plugin install context-mode@context-mode`, **and** install the CLI globally with `npm install -g context-mode` (the [install.sh](https://github.com/sgaabdu4/claude-code-tips/blob/main/install.sh) does both for you). The plugin registers the MCP tools, but the global install is what puts the `context-mode` binary on PATH — the hooks call `context-mode hook claude-code <event>`, so without it they fail with "command not found". One hook per lifecycle event (`PreToolUse`/`PostToolUse`/`PreCompact`/`SessionStart`). See [`settings/settings.json`](https://github.com/sgaabdu4/claude-code-tips/blob/main/settings/settings.json).

Tip: add a sibling PreToolUse hook on your test runner (`npm test`, `pytest`, `go test ./...`) that nudges Claude (non-blocking) to use `ctx_batch_execute`. Whole suites produce thousands of lines.

---

## Layer 3: RTK - Rust Token Killer (60-90% on Shell Output)

**Repo:** [github.com/rtk-ai/rtk](https://github.com/rtk-ai/rtk)

**What it does:** A Rust binary that intercepts CLI command output and compresses it before it enters the context window. Strips boilerplate, groups similar items, truncates long output, deduplicates repeated entries. Single binary, <10ms overhead, no network calls.

**Real numbers:**

https://gist.github.com/sgaabdu4/b38789426177346f00d546eb27f87c9b

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

https://gist.github.com/sgaabdu4/67aa0360409be437dbd6bfff85d7cd76

### Setup: one shell function

[`install.sh`](https://github.com/sgaabdu4/claude-code-tips/blob/main/install.sh) drops a `claude` shell function into your `.bashrc`/`.zshrc`/`.config/fish/config.fish` that wraps the binary with `headroom wrap claude -- "$@"` (`-- $argv` in Fish). The separator matters: Claude's `-p` print-mode flag otherwise collides with Headroom's `-p/--port` option. The wrapper boots a local proxy, sets `ANTHROPIC_BASE_URL`, and launches Claude. `--resume`, `-p "query"`, all args pass through. RTK rides inside the Headroom binary and auto-registers as the inner CLI proxy. No separate setup.

---

## Layer 5: Caveman Plugin (50-75% on Claude's Own Output)

**Repo:** [github.com/JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman)

Most people forget this one. **Claude's own verbose responses count against your context window.** Every "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by..." is tokens you paid for and got nothing back.

Caveman is a Claude Code plugin that flips Claude into a compressed register. Articles, filler, hedging, pleasantries: gone. Technical substance survives untouched.

**Before:**
> "Sure! I'd be happy to help you with that. The issue you're experiencing is likely caused by a race condition in the authentication middleware where the token expiry check uses a strict less-than comparison instead of less-than-or-equal."

**After:**
> "Bug in auth middleware. Token expiry check use `<` not `<=`. Fix:"

### Not just a speaking style

Caveman ships with automatic hooks and sub-skills:

- **`/caveman:compress`**: Compresses your CLAUDE.md and memory files *permanently* into caveman format. Saves tokens on every single future session start since CLAUDE.md is loaded into context every time. This is a multiplicative saving.
- **`/caveman:caveman-commit`**: Compressed commit message generator. Subject ≤50 chars, body only when "why" isn't obvious.
- **`/caveman:caveman-review`**: Compressed code review comments. Each comment is one line: location, problem, fix.
- **`/caveman-help`**: Quick reference for all modes and commands.

**Intensity levels:** `lite` (gentle compression), `full` (classic caveman, default), `ultra` (maximum compression).

### Installation

Caveman installs through the Claude Code third-party plugin marketplace. Enable it in `settings.json` under `enabledPlugins` and add an `extraKnownMarketplaces` entry pointing at `JuliusBrussee/caveman`. Hooks auto-activate on `SessionStart` and `UserPromptSubmit`. Full snippet in the [companion `settings.json`](https://github.com/sgaabdu4/claude-code-tips/blob/main/settings/settings.json).

---

## Bonus hook: bash-ban-raw-tools

Sibling to the CBM gate. Problem: when Claude runs `cat file.py` or `grep "pattern" src/` via Bash, raw output bypasses every compression hook. `Read`/`Grep` are throttled by MCP + context-mode, but Bash goes straight to context.

Fix: a Bash PreToolUse hook that blocks the raw commands (`cat`/`head`/`tail`/`find`/`grep`/`rg`/`wc`) and forces Claude through the compressed tools, while letting RTK wrappers pass through and additionally rejecting `| tail`/`| head` truncation pipes (which still flood context before the trim). Escape hatch: `touch /tmp/bash-raw-unlock-$PPID` for current-session-only, or `touch /tmp/bash-raw-unlock` to unlock every session on the machine. Both auto-expire after 10 min. Full file: [`hooks/bash-ban-raw-tools`](https://github.com/sgaabdu4/claude-code-tips/blob/main/hooks/bash-ban-raw-tools).

---

## The Complete settings.json

Full file: [`settings/settings.json`](https://github.com/sgaabdu4/claude-code-tips/blob/main/settings/settings.json). Top-level shape:

- **`env`**: 8 framework keys (covered below).
- **`permissions.defaultMode: auto`**: fewer permission prompts mid-flow.
- **`model: claude-opus-4-7`** + **`effortLevel: xhigh`** + **`advisorModel: opus`**: primary model, reasoning budget, advisor escalation target.
- **`statusLine`**: points at `statusline-command.sh`.
- **`enabledPlugins`**: `caveman@caveman`, `context-mode@context-mode` (each with a matching `extraKnownMarketplaces` entry).
- **`hooks`**: one entry per lifecycle event.
    - `PreToolUse`: Bash routes through `context-mode` + `bash-ban-raw-tools` + `flutter-ctx-redirect` + `rtk`; `Grep|Glob|Read|Search` routes through `cbm-code-discovery-gate`.
    - `PostToolUse`: `context-mode` + `cbm-mcp-marker`; `Edit|Write|MultiEdit` fires the sync hooks.
    - `PreCompact`: `context-mode`.
    - `SessionStart`: matcherless `context-mode` + `memory-repo-symlink` + `cbm-session-reminder`, plus `startup`/`resume`/`clear`/`compact` matchers each running `cbm-session-reminder`.

### What each env var does

Headliners. `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=50` fires compaction at 50% of the context window instead of the default 95%, keeping long sessions off the ceiling. `CLAUDE_CODE_SUBAGENT_MODEL=claude-sonnet-4-6` pins delegated subagents to Sonnet 4.6 (60% cheaper than Opus, plenty smart for research, refactor, audit). `ENABLE_PROMPT_CACHING_1H=1` stretches the prompt cache TTL from 5 minutes to 1 hour, a serious cost saver on long sessions. Full table:

https://gist.github.com/sgaabdu4/f352f61e23f41f331c7d5a5985bc9604

### Other settings explained

`effortLevel: xhigh` keeps Opus 4.7 reasoning unlocked (it's also the 4.7 default; drop to `medium` when you're cost-sensitive). `advisorModel: opus` routes the built-in advisor tool to the strongest model for second opinions. Subagents inherit `claude-sonnet-4-6` from the env var by default. Override per-agent with `model: claude-opus-4-7` in `~/.claude/agents/<name>.md` frontmatter when the stakes are high (refactor, multi-file impact, audit). Full table:

https://gist.github.com/sgaabdu4/9ef5dd71813217c695ee5f5944c49680

---

## The CLAUDE.md That Makes It Work

Your CLAUDE.md is instructions for *in-session* behavior. Don't document external tools (Headroom, RTK) here. They operate outside the session and Claude can't see them. Only instruct on the tools Claude actively calls.

Full file: [`CLAUDE.md.example`](https://github.com/sgaabdu4/claude-code-tips/blob/main/CLAUDE.md.example). Sections it covers:

- **Principles**: DRY/KISS/YAGNI/SSOT, read code first, fail→change approach, ask before destructive.
- **Implementation Flow**: 10-step ordered routine Claude must run for every implementation task (Index → Skill gate → Clarify → Explore via CBM → Plan → Delegate? → Ripple → TDD → Verify → Advisor). Skip a step, STOP, restart from skipped.
- **Skill gates**: pattern for routing stack files at the per-stack skill (stack rule loads first, no skip).
- **Ripple check**: any add/change/remove must `trace_path` ALL call sites. Never trust "only used here".
- **TDD**: red/green/refactor with explicit edge-case list (empty/null/boundary/concurrency/tz/unicode/overflow/permission/network/partial).
- **Tools Quickref**: single-table mapping of intent to tool (`search_graph` for find-def, `trace_path` for flow, `ctx_execute` for run, `ctx_fetch_and_index` for URLs, etc.).
- **Banned Bash**: `cat`/`head`/`tail`/`grep`/`find` are blocked. Use Read/Grep/Glob tools instead.
- **Subagents**: when to delegate (MANDATORY for research, refactor >2 files, audit, multi-file impact), parallel cap 3, frontmatter fields (`permissionMode: plan` for read-only audit agents, `isolation: worktree`, `model: claude-opus-4-7`, `effort: xhigh`).
- **Reply style**: min tokens, answer first, no filler, no preamble, no recap.

### Per-language rule files

I also use `.claude/rules/` for stack-specific enforcement. Loaded via `@` import from `CLAUDE.md`. One file per stack. Skill to invoke first, numbered self-check of the handful of footguns Claude repeatedly trips on. Build the list from actual failures you've seen.

**The repo ships `rules/` empty.** Just [`rules/README.md`](https://github.com/sgaabdu4/claude-code-tips/blob/main/rules/README.md) as a template. Listing my flutter/react/appwrite rules in the install would either pollute your context with stuff you don't ship, or imply they apply when they don't. The three I run (shown below as article examples, not shipped as files):

#### Flutter
- Scope: `**/*.dart`, `**/pubspec.yaml`, `**/analysis_options.yaml`.
- Invoke `building-flutter-apps` skill FIRST.
- `if (!ref.mounted) return;` after every `await` in a notifier. `if (!context.mounted) return;` after every `await` in a widget/State. Never bare `mounted`; the lint fires. Extract a sync helper on State with `this.context`.
- No `_buildXxx()`. Extract widget classes. No hardcoded strings. Use `*Strings` constants.
- `ref.watch` in build, `ref.read` in callbacks. Riverpod 3.x codegen naming: `FooNotifier` → `fooProvider`. No `shrinkWrap: true` on `ListView`/`GridView`.

#### React/Next
- Scope: `**/*.tsx`, `**/*.jsx`, `**/*.ts`, `**/next.config.*`, `**/package.json`.
- Invoke `vercel-react-best-practices` skill FIRST.
- Server Components default. `"use client"` only for interaction.
- Heavy compute (`find`/`filter`/`sort`/tz/O(n) scans) → `useMemo` with stable deps. Never in `.map()` callbacks, JSX attrs, or render body.
- No `enum`. Use `as const` objects. Status variants → `Record<Status, Variant>` map, not ternary chains.

#### Appwrite
- Scope: any TablesDB/Auth/Storage/Functions/Realtime work.
- Invoke `appwrite-backend` skill FIRST.
- Backend compliance agent must: grep all `Query.select([...])` calls, extract field names, fetch live schema via Appwrite CLI (`appwrite databases list-attributes --database-id <id> --table-id <id>`), flag selected fields not in collection attrs, flag missing indexes on queried fields.

Copy the **structure**, not the content. Each rule opens with `Invoke <skill> FIRST`. That's the load-bearing line. Swap in your own stacks. The point is one skill-gated rule file per framework you actually ship, not these specific three.

### Additional hooks

Four more hooks live in the production config. `flutter-ctx-redirect` (PreToolUse Bash) pipes Flutter/Dart tool output through context-mode. `memory-repo-symlink` (SessionStart) scopes agent memory to the current project. `sync-copilot-on-edit` and `sync-runner-tools-on-edit` (both PostToolUse Edit|Write|MultiEdit) mirror slash commands into VS Code Copilot prompts and rewrite e2e runner tool-allowlists after each edit. The pair also works around subagent MCP inheritance bug [#30280](https://github.com/anthropics/claude-code/issues/30280).

### Slash commands

Beyond the core hooks: `/unleash` spawns the full agent review swarm in parallel (lint, types, security, perf, DB-schema, UX, reuse). `/e2e` runs the end-to-end suite via the stack-appropriate runner agent. `/e2e-auto` does the same with auto-detected project type.

### The 21-agent ecosystem

`~/.claude/agents/` holds 21 specialists in four categories: **stack auditors** (react, flutter, appwrite, web-ui), **role agents** (api-designer, security, perf, devops, ux, edge-case-hunter, reuse, user-flow, qa, junior-dev, naive-tester), **meta** (staff-engineer, general-purpose, Plan, Explore), **e2e runners** (web, flutter). Each declares `skills:`, `model:`, `permissionMode:`, and `isolation:` in its own frontmatter.

### Codegen pipeline

`bin/sync-copilot.mjs` symlinks `~/.claude/commands/*.md` into VS Code prompt directories as `*.prompt.md` after each command edit (triggered by `sync-copilot-on-edit`). `bin/sync-runner-tools.mjs` rewrites runner agent tool-allowlists to match the current MCP inventory (`sync-runner-tools-on-edit`). Both are idempotent; run the installed copies manually from `~/.claude/bin/` to force a full resync.

---

## Custom Status Line

Colour-coded dashboard. One line, every signal: user, cwd, branch, model, context %, 5-hour usage %, 7-day usage %, clock.

```
user in ~/project on  main │ ⬡ o4.7 │ ctx ████░░░░ 48% │ 5h ██░░░░░░ 23% │ 7d █░░░░░░░ 12% │ 09:59
```

Point `statusLine.command` at [`statusline/statusline-command.sh`](https://github.com/sgaabdu4/claude-code-tips/blob/main/statusline/statusline-command.sh).

---

## Results

Headline numbers: sessions go from ~30 min to 3+ hours on the same 200K window. Tokens per code exploration drop from ~400K to ~3.4K. Shell output lands at 10-40% of original, API payload at 8-53%, Claude's own response verbosity at 25-50%. Full before/after table:

https://gist.github.com/sgaabdu4/441d7cf66c30c62db122ba55a9e277f9

Layers compound. Each catches what the previous missed.

## Install

```bash
git clone https://github.com/sgaabdu4/claude-code-tips.git
cd claude-code-tips && chmod +x install.sh && ./install.sh
```

The installer is opinionated and ships a power-user default. It drops in Headroom (which bundles RTK), codebase-memory-mcp, the context-mode plugin, the Caveman plugin, every hook, the slash commands, stack rule templates, `bin/` helpers, statusline, `settings.json`, and shell wrappers (fish/bash/zsh). It will not ship or overwrite private subagent definitions in `~/.claude/agents/`. Your existing `~/.claude/settings.json` is backed up before anything is written.

Escape hatches:

```bash
./install.sh --no-shell-wrapper   # install Headroom/RTK, but launch compression manually
./install.sh --no-caveman         # skip Caveman plugin and omit it from settings
./install.sh --sonnet             # use model: sonnet + effortLevel: high
./install.sh --check              # validate every hook/command/bin reference
```

Use `--no-shell-wrapper` if you want to inspect the stack before making `claude` auto-wrap through Headroom. Manual launch is `headroom wrap claude -- <claude args>`. Tune `model` / `effortLevel` / `advisorModel` after install if you have a different account profile.

## Bonus: The workflow this unlocks

With 3h sessions instead of 30min, multi-model pipelines stop hitting limits. Mine:

1. **Plan**: Claude Opus 4.7, or `/ultraplan` to offload the plan to a cloud session while I keep working locally.
2. **Implement**: Claude Opus 4.7.
3. **Review round 1**: `/unleash` subagent swarm in parallel: lint, types, security, perf, DB-schema check.
4. **Review round 2**: a different intelligent model for a cross-model second opinion. I use Codex (GPT-5.5) because the vendor switch catches blind spots a same-family reviewer misses, but another Claude or Gemini works fine.
5. **E2E**: same principle: any strong model driving a browser. Codex + VS Code integrated browser works; so does Claude via [Agent Browser's `dogfood` skill](https://github.com/vercel-labs/agent-browser) (clicks every button, tests forms with edge cases, **records video when it finds a potential bug**). For Flutter, the official [Dart MCP](https://docs.flutter.dev/tools/mcp) + Flutter Driver lets the LLM drive real devices end-to-end.

**Model choice, honestly:** swap them out and you'd barely notice. Opus 4.7 high+ for plan and implement is what I run. Any GPT-5.3+ Codex (high/xHigh) or same-class Claude covers review and E2E. Cross-vendor review catches more than same-vendor review. The only floor is "intelligent enough." Don't review Opus output with Haiku. For background subagents (research, audit, refactor) Sonnet 4.6 via `CLAUDE_CODE_SUBAGENT_MODEL` is the sweet spot. 60% cheaper than Opus, plenty smart, with per-agent Opus override for high-stakes work.

Tavily stays hot in the session for live research. Never trust training data for docs, signatures, or versions.

Other things that moved the needle:

- **Reject scanners on PostToolUse hooks**: every edit triggers a structural-standards scan. Any hit goes straight back to Claude so it fixes before moving on. Concrete stack: a [custom ESLint rule](https://eslint.org/docs/latest/extend/custom-rules) for TS/JS, a node regex scanner for domain UI patterns, a [Dart analyzer plugin](https://dart.dev/tools/analyzer-plugins) wired through `analysis_options.yaml` for Dart, all gated pre-commit by [Husky](https://github.com/typicode/husky) + [lint-staged](https://github.com/lint-staged/lint-staged).
- **CLI over MCP**: ripped out Tavily + Appwrite MCP servers in favour of their CLIs (`tvly`, `appwrite`). Paired with context-mode, same power, way less context bloat.
- **Only 2 MCP servers:** `codebase-memory-mcp` + `context-mode`. Everything else is CLI or hooks.
- **Fluid Voice** for dictation (Parakeet/Nvidia under the hood): beats stock dictation because it AI-edits as you speak.
- **Measure what you're saving.** [Codeburn](https://github.com/getagentseal/codeburn) is a TUI dashboard that shows per-session token cost across Claude Code, Codex, and Cursor. Closes the loop. You can see when the stack is actually paying off.

---

## Closer

Don't *tell* Claude to be efficient. *Enforce* it. One hook that blocks a wasteful pattern beats 1,000 words of CLAUDE.md. Claude takes the path of least resistance every time. Make the efficient path the only path that exists.
