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

Sanity-checks `git`/`curl`/`jq`/`python3` upfront. Installs Headroom (`pip install --user`), CBM binary, context-mode + Caveman plugins via `claude plugin install`, hooks, statusline, settings, shell wrapper for your `$SHELL`. **Idempotent** — re-run anytime.

### Power-user flags

Default stays maximal. These flags narrow blast radius without editing the script:

```bash
./install.sh --no-shell-wrapper   # install Headroom/RTK, but do not alias claude
./install.sh --no-caveman         # skip Caveman plugin + omit it from settings
./install.sh --opus               # use model: opus + effortLevel: xhigh (default is sonnet/xhigh)
./install.sh --check              # validate repo wiring only
```

`--no-shell-wrapper` is the safer alternative to skipping Headroom entirely: this stack relies on Headroom to provide RTK, so the flag keeps the binary installed while making API-layer compression an explicit `headroom wrap claude -- <claude args>` launch choice.

### Existing setup? Don't worry

- `~/.claude/CLAUDE.md` — your content preserved. Our framework is prepended inside `<!--cct-->`/`<!--/cct-->` markers. Re-runs replace inside markers; everything outside untouched.
- `~/.claude/settings.json` — `jq` deep merge. Your `model` / `effortLevel` / `permissions` / custom env keys preserved. Our `hooks` and framework env added.
- `~/.claude/{hooks,commands,rules}/*` — per-file: if a target exists and differs from ours, renamed to `<name>.bak.<timestamp>` before overwrite. Identical files: no-op.

### Validate

```bash
./install.sh --check
```

Walks `settings.json`, asserts every hook command path resolves on disk and every `mcp__plugin_*` reference in commands has a matching `enabledPlugins` entry. Catches "hook referenced but not installed" forever.

## Layout

| Path | Purpose |
|---|---|
| [`install.sh`](./install.sh) | One-click power-user install. Supports `--check`, `--no-shell-wrapper`, `--no-caveman`, and `--opus`. |
| [`settings/settings.json`](./settings/settings.json) | `~/.claude/settings.json` — model, effort, hooks, env, plugins, statusline |
| [`CLAUDE.md.example`](./CLAUDE.md.example) | Body of `~/.claude/CLAUDE.md` — rules + tool routing. Wrapped in `<!--cct-->` markers when installed |
| [`hooks/`](./hooks/) | All enforcement hooks (cbm-*, bash-ban-raw-tools, memory-repo-symlink) |
| [`rules/`](./rules/) | **Empty by design** — your stack-specific rules. See [`rules/README.md`](./rules/README.md) for the template |
| [`statusline/statusline-command.sh`](./statusline/statusline-command.sh) | Statusline — user, branch, model, ctx%, 5h/7d usage |

## Hook map

```
shell wrapper           claude → headroom wrap claude
PreToolUse(Bash)        context-mode + bash-ban-raw-tools + rtk
PreToolUse(Grep|...)    cbm-code-discovery-gate
PostToolUse             context-mode + cbm-mcp-marker
PreCompact              context-mode
SessionStart            context-mode + memory-repo-symlink + cbm-session-reminder
```

## Externals (auto-installed by `install.sh`)

| Tool | Repo |
|---|---|
| Headroom (bundles RTK) | https://github.com/chopratejas/headroom |
| codebase-memory-mcp | https://github.com/DeusData/codebase-memory-mcp |
| context-mode plugin | https://github.com/mksglu/context-mode |
| Caveman plugin | https://github.com/JuliusBrussee/caveman |
| RTK standalone | https://github.com/rtk-ai/rtk |

## Read the full story

The Medium post walks through the *why* of each layer, the failure modes that drove every hook, and the cost math. Start there: [`claude-code-tips.md`](./claude-code-tips.md).
