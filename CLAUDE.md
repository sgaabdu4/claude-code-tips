# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A **distribution + installer** for a personal Claude Code token-optimization stack — not a runnable application. Every source file here is a config artifact that `install.sh` deploys into `~/.claude/`. There is no application runtime, no language toolchain, and no test suite. "Correctness" means the artifacts wire together; the validator (`./install.sh --check`) is the closest thing to a test.

The companion Medium post (`claude-code-tips.md`) is the long-form narrative; `README.md` is the user-facing install guide. The stack layers (from `README.md:9`): CBM (code graph) + context-mode (output sandbox) + RTK (shell compression) + Headroom (API layer) + Caveman (output style) + enforcement hooks.

## Commands

```bash
./install.sh                 # idempotent power-user install into ~/.claude/
./install.sh --check         # VALIDATOR — run this after editing settings/hooks/commands/bin
./install.sh --no-shell-wrapper   # install Headroom but don't alias `claude`
./install.sh --no-caveman         # drop caveman plugin from merged settings
./install.sh --sonnet             # model: sonnet + effortLevel: high (default is opus/xhigh)

node bin/sync-copilot.mjs --check        # assert VSCode prompt symlinks in sync
node bin/sync-runner-tools.mjs --dry-run # preview agent `tools:` line regen (probes live MCP)
node bin/sync-runner-tools.mjs --check   # exit 1 on drift
```

`./install.sh --check` is the CI-equivalent. Run it after any edit to `settings/settings.json`, `hooks/`, `commands/`, or `bin/` — it catches the cross-file breakages described below. The `bin/` scripts are zero-dependency Node ESM (no `package.json`, no `npm install`); hooks are POSIX bash. Required external tools: `git`, `curl`, `jq`, `python3`.

## How install works (the big picture)

`install.sh` never blindly overwrites a user's existing `~/.claude/`. Three different merge strategies, one per artifact type:

- **`CLAUDE.md.example` → `~/.claude/CLAUDE.md`** (`inject_claude_md`, `install.sh:294`): the body is injected between `<!--cct-->` / `<!--/cct-->` markers. Re-runs replace only the marked block (via `awk`); user content outside the markers is preserved. An orphaned start-marker-without-end aborts loud rather than truncating.
- **`settings/settings.json` → `~/.claude/settings.json`** (`merge_settings_json`, `install.sh:381`): a `jq` deep merge. The `hooks` block is **owned** by this repo (replaced wholesale). User `model` / `effortLevel` / `permissions` / custom `env` are preserved (`//=`). `enabledPlugins` + `extraKnownMarketplaces` are unioned. `--no-caveman` and `--sonnet` apply as `jq` deletions/overrides in `prepare_settings_source` *before* the merge.
- **`hooks/` `commands/` `rules/*.md` `agents/*.md` `bin/` `statusline/` → flat copy** (`cp_with_backup`, `install.sh:283`): per-file. If the target exists and differs, it's renamed to `<name>.bak.<ts>.<pid>` before overwrite; identical files are a no-op. Because `agents/` is copied per-file, private/runtime agents already in `~/.claude/agents/` (e.g. `e2e-*-runner`) are left untouched — only the repo's own agent files are written.

Symlinked targets are resolved before writing so `mv`/overwrite edits the real file instead of orphaning the symlink. Everything is idempotent — re-run anytime.

## Cross-file invariants (what `--check` enforces)

These bind multiple files together; breaking one fails `./install.sh --check` (`install.sh:95`–`146`):

1. **Hook in settings ⇒ file in repo.** Every `~/.claude/hooks/<name>` command path in `settings/settings.json` must have a matching `hooks/<name>` file. Add a hook → register its command path in settings; rename a hook → rename in both places.
2. **Command plugin ref ⇒ enabled plugin.** Every `mcp__plugin_<x>_*` token in `commands/*.md` must have a `<x>@*` entry under `enabledPlugins` in settings. The `/e2e*` commands reference `mcp__plugin_context-mode_*`, so context-mode must stay enabled.
3. **Hook-referenced bin script ⇒ exists.** `sync-copilot.mjs` / `sync-runner-tools.mjs` are referenced by the `sync-*-on-edit` hooks and must exist in `bin/`.

## Hook architecture

The deployed hooks (`hooks/`, wired in `settings/settings.json:19`):

- **`bash-ban-raw-tools`** (PreToolUse/Bash): blocks `cat`/`head`/`tail`/`find`/`grep`/`rg`/`wc` and `cat|grep|rg|find` piped into `head`/`tail`, steering to Read/Grep/Glob/ctx_batch_execute. `rtk` wrappers pass. Escape hatch: `touch /tmp/bash-raw-unlock` (10-min expiry). Deliberately avoids `set -e` so malformed stdin JSON falls through to allow, never a false block.
- **`cbm-code-discovery-gate`** (PreToolUse/Grep|Glob|Read|Search) + **`cbm-mcp-marker`** (PostToolUse): paired gate. The marker (`/tmp/cbm-mcp-used-$PPID`) is touched whenever a `mcp__codebase-memory-mcp__*` tool runs; the gate blocks the *first* raw search per session unless that marker (or its own one-shot `$GATE` file) exists. `$PPID` scopes both to one Claude session.
- **`cbm-session-reminder`** (SessionStart): prints the CBM-first discovery protocol.
- **`memory-repo-symlink`** (SessionStart): points `~/.claude/projects/<slug>/memory` at `<repo>/.claude/memory` (or `<root>/memory` for the `~/.claude` repo itself) so memory files live in-repo and are committable.
- **`flutter-ctx-redirect`** (PreToolUse/Bash): *warning only* (exit 0) — nudges bare `flutter test`/`analyze` toward ctx_batch_execute; scoped runs pass quietly.
- **`sync-copilot-on-edit`** / **`sync-runner-tools-on-edit`** (PostToolUse/Edit|Write): fire the matching `bin/` script in the background when a relevant file is edited. Both short-circuit on a cheap string match before the python JSON parse to stay sub-millisecond in unrelated projects.

## What is intentionally NOT shipped

- **`rules/` ships empty** (only `rules/README.md`). Stack rules are project-specific; don't add personal ones. The README is the template — each rule's first body line after frontmatter must be `Invoke <skill-name> FIRST` (the load-bearing routing line).
- **`agents/` ships only the `/ship` discovery + stack-auditor subagents.** The repo's `agents/` holds the generic discovery agents (`edge-case-hunter`, `reuse-auditor`, `staff-engineer`, `qa-engineer`) and the Python/Django + Vue stack auditors (`django-auditor`, `vue-auditor`, `web-ui-auditor`, `ux-reviewer`, `security-reviewer`) referenced by `commands/ship.md` Phase 1 — installed via the per-file flat copy above. **Other agents stay private/runtime and are NOT in this repo:** `bin/sync-runner-tools.mjs` and `sync-runner-tools-on-edit` target `~/.claude/agents/e2e-*-runner.md` *at runtime* — the file they rewrite is not in this repo — and the `/e2e*` commands load an `e2e-protocol` skill that lives outside this repo. `--check` does **not** validate that `ship.md` agent names resolve to files (stack-conditional agents are intentionally skippable per `ship.md` "skip + note the gap"); the agent name ↔ file match is a manual cross-check.
- The two `bin/` sync scripts exist because subagent `tools:` frontmatter wildcards are broken upstream (`anthropics/claude-code#17928`, `#30280`), so the full MCP tool list must be hand-materialized — which `sync-runner-tools.mjs` automates by speaking MCP stdio JSONRPC to each server.

## Editing conventions

- Keep `install.sh` POSIX-bash and idempotent; preserve the backup-on-conflict and symlink-resolution guards when touching the merge helpers.
- The `bin/` scripts support `--dry-run` / `--check` / `--only <name>` and must stay dependency-free.
- After editing any wired artifact, run `./install.sh --check` and quote its output before claiming the change is complete.
