# Claude Code Token-Optimisation Stack

Configs + hooks + scripts for Medium post: **"How I Cut Claude Code Token Usage by 90%+"**.

This repo is intentionally a **power-user default**: it assumes you want aggressive token control, enforcement hooks, and a local shell wrapper. If you want the full stack, run the default installer. If you want less global surface area, use the opt-out flags below.

Post: [`claude-code-tips.md`](./claude-code-tips.md)

Stack: **CBM** (code graph) + **context-mode** (output sandbox) + **RTK** (shell compression) + **Headroom** (API-layer) + **Caveman** (Claude output) + enforcement hooks. ~30min → 3h+ sessions, same 200K window.

## Install

```bash
git clone https://github.com/sgaabdu4/claude-code-tips.git
cd claude-code-tips && chmod +x install.sh && ./install.sh
```

Sanity-checks `git`/`curl`/`jq`/`python3` upfront. Installs Headroom (`pip install --user`), CBM binary, context-mode + Caveman plugins via `claude plugin install`, hooks, slash commands, statusline, settings, shell wrapper for your `$SHELL`. **Idempotent** — re-run anytime.

### Power-user flags

Default stays maximal. These flags narrow blast radius without editing the script:

```bash
./install.sh --no-shell-wrapper   # install Headroom/RTK, but do not alias claude
./install.sh --no-caveman         # skip Caveman plugin + omit it from settings
./install.sh --sonnet             # use model: sonnet + effortLevel: high
./install.sh --check              # validate repo wiring only
```

`--no-shell-wrapper` is the safer alternative to skipping Headroom entirely: this stack relies on Headroom to provide RTK, so the flag keeps the binary installed while making API-layer compression an explicit `headroom wrap claude -- <claude args>` launch choice.

### Existing setup? Don't worry

- `~/.claude/CLAUDE.md` — your content preserved. Our framework is prepended inside `<!--cct-->`/`<!--/cct-->` markers. Re-runs replace inside markers; everything outside untouched.
- `~/.claude/settings.json` — `jq` deep merge. Your `model` / `effortLevel` / `permissions` / custom env keys preserved. Our `hooks` and framework env added.
- `~/.claude/{hooks,commands,rules,bin}/*` — per-file: if a target exists and differs from ours, renamed to `<name>.bak.<timestamp>` before overwrite. Identical files: no-op.
- `~/.claude/agents/*` — intentionally untouched. Keep your private subagent definitions outside this public repo.

### Validate

```bash
./install.sh --check
```

Walks `settings.json`, asserts every hook command path resolves on disk, every `mcp__plugin_*` reference in commands has a matching `enabledPlugins` entry, every `bin/` script referenced by a hook exists. Catches "hook referenced but not installed" forever.

It also resolves the **CLI each hook actually runs** (`rtk`, `context-mode`) the way a hook would — no shell rc — and prints a `WARN` when one is unreachable. Run the test suite with:

```bash
./tests/run-cli-hook.test.sh
```

## Layout

| Path | Purpose |
|---|---|
| [`install.sh`](./install.sh) | One-click power-user install. Supports `--check`, `--no-shell-wrapper`, `--no-caveman`, and `--sonnet`. |
| [`settings/settings.json`](./settings/settings.json) | `~/.claude/settings.json` — model, effort, hooks, env, plugins, statusline |
| [`CLAUDE.md.example`](./CLAUDE.md.example) | Body of `~/.claude/CLAUDE.md` — rules + tool routing. Wrapped in `<!--cct-->` markers when installed |
| [`hooks/`](./hooks/) | All enforcement hooks (cbm-*, bash-ban-raw-tools, sync-*-on-edit, flutter-ctx-redirect, memory-repo-symlink) plus `run-cli-hook`, the PATH-resilient shim every external CLI hook goes through |
| [`tests/`](./tests/) | Sandboxed tests (throwaway `$HOME`, never touches your real `~/.claude`) |
| [`commands/`](./commands/) | Slash commands (`/e2e`, `/e2e-auto`, `/unleash`, `/ship`) |
| [`rules/`](./rules/) | **Empty by design** — your stack-specific rules. See [`rules/README.md`](./rules/README.md) for the template |
| [`bin/`](./bin/) | Helper scripts (`sync-copilot.mjs`, `sync-runner-tools.mjs`) referenced by hooks |
| [`statusline/statusline-command.sh`](./statusline/statusline-command.sh) | Statusline — user, branch, model, ctx%, 5h/7d usage |

Subagent definitions are private by design. The commands can call local agents from `~/.claude/agents/`, but this repo does not ship or overwrite them.

## Hook map

```
shell wrapper           claude → headroom wrap claude
PreToolUse(Bash)        run-cli-hook context-mode + bash-ban-raw-tools + flutter-ctx-redirect + run-cli-hook rtk
PreToolUse(Grep|...)    cbm-code-discovery-gate
PostToolUse             context-mode + cbm-mcp-marker
PostToolUse(Edit|Write) sync-copilot-on-edit + sync-runner-tools-on-edit
PreCompact              context-mode
SessionStart            context-mode + memory-repo-symlink + cbm-session-reminder
```

### Why hooks go through `run-cli-hook`

Claude Code spawns hook commands **without sourcing your shell rc**, so a hook only sees the PATH the Claude Code process inherited. Headroom installs `rtk` into `~/.headroom/bin`, `pip --user` and `npm -g` land elsewhere again, and none of those dirs are on that PATH. A bare `rtk hook claude` therefore dies with:

```
PreToolUse:Bash hook error
Failed with non-blocking status code: [rtk: No such file or directory (os error 2)]
```

— while the exact same command works when *you* run it, because the Bash tool does load your profile.

`hooks/run-cli-hook` resolves the binary itself (PATH → `~/.headroom/bin` → `~/.local/bin` → Homebrew → cargo/bun/volta/nvm → `pip --user` base) and execs it. If the CLI genuinely isn't installed it exits 0 silently, so a missing optional tool never blocks a tool call. Installed somewhere exotic? Point it there explicitly:

```bash
export CCT_RTK_BIN="$HOME/.headroom/bin/rtk"
```

Same pattern for any shimmed CLI — `CCT_CONTEXT_MODE_BIN`, etc.

## Externals (auto-installed by `install.sh`)

| Tool | Repo |
|---|---|
| Headroom (bundles RTK) | https://github.com/headroomlabs-ai/headroom |
| codebase-memory-mcp | https://github.com/DeusData/codebase-memory-mcp |
| context-mode plugin | https://github.com/mksglu/context-mode |
| Caveman plugin | https://github.com/JuliusBrussee/caveman |
| RTK standalone | https://github.com/rtk-ai/rtk |

### Optional — required only for `/e2e` and `/e2e-auto`

| Tool | Install |
|---|---|
| flutter-driver-mcp (Flutter projects) | `claude mcp add --transport stdio flutter-driver -- npx flutter-driver-mcp` |
| agent-browser (web projects) | `npm install -g agent-browser` |

`install.sh` does **not** install these — the e2e commands abort with the relevant install hint if you run them without the tool.

## Read the full story

The Medium post walks through the *why* of each layer, the failure modes that drove every hook, and the cost math. Start there: [`claude-code-tips.md`](./claude-code-tips.md).
