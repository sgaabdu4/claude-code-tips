# Claude Code Token-Optimisation Stack

Configs + hooks + scripts for Medium post: **"How I Cut Claude Code Token Usage by 90%+"**.

Post: [`claude-code-tips.md`](./claude-code-tips.md)

Stack: **CBM** (code graph) + **context-mode** (output sandbox) + **RTK** (shell compression) + **Headroom** (API-layer) + **Caveman** (Claude output) + enforcement hooks. ~30min → 3h+ sessions, same 200K window.

## Files

| Path | Purpose |
|---|---|
| [`install.sh`](./install.sh) | One-click install — deps, hooks, settings, statusline, wrappers |
| [`settings/settings.json`](./settings/settings.json) | `~/.claude/settings.json` — hooks, env, plugins, statusline |
| [`CLAUDE.md.example`](./CLAUDE.md.example) | `~/.claude/CLAUDE.md` — in-session rules + tool routing |
| [`hooks/bash-ban-raw-tools`](./hooks/bash-ban-raw-tools) | PreToolUse — blocks `cat`/`head`/`tail`/`find`/`grep`/`rg`/`wc` |
| [`hooks/cbm-code-discovery-gate`](./hooks/cbm-code-discovery-gate) | PreToolUse — blocks `Grep`/`Glob`/`Read` on source until CBM called |
| [`hooks/cbm-mcp-marker`](./hooks/cbm-mcp-marker) | PostToolUse — touches marker on CBM calls |
| [`hooks/cbm-session-reminder`](./hooks/cbm-session-reminder) | SessionStart — re-injects CBM protocol post `/clear`, `/compact` |
| [`statusline/statusline-command.sh`](./statusline/statusline-command.sh) | Statusline — user, branch, model, ctx%, 5h/7d usage |
| [`rules/flutter.md`](./rules/flutter.md) · [`react.md`](./rules/react.md) · [`appwrite.md`](./rules/appwrite.md) | Per-stack self-check gates |
| [`shell/claude.{fish,bash,zsh}`](./shell/) | Shell wrapper — `claude` → `headroom wrap claude` |

## Install

```bash
chmod +x install.sh && ./install.sh
```

Backs up existing `~/.claude/settings.json`. Tune `model` / `effortLevel` / `advisorModel` post-install.

## Manual install

```bash
mkdir -p ~/.claude/hooks ~/.claude/rules
cp hooks/* ~/.claude/hooks/ && chmod +x ~/.claude/hooks/*
cp rules/*.md ~/.claude/rules/
cp ~/.claude/settings.json{,.bak} 2>/dev/null || true
cp settings/settings.json ~/.claude/settings.json
cp CLAUDE.md.example ~/.claude/CLAUDE.md
cp statusline/statusline-command.sh ~/.claude/ && chmod +x ~/.claude/statusline-command.sh

# Shell wrapper — pick one
cat shell/claude.fish >> ~/.config/fish/config.fish
cat shell/claude.bash >> ~/.bashrc
cat shell/claude.zsh  >> ~/.zshrc
```

Then install externals:

| Tool | Repo |
|---|---|
| Headroom (bundles RTK) | https://github.com/chopratejas/headroom |
| codebase-memory-mcp | https://github.com/DeusData/codebase-memory-mcp |
| context-mode | https://github.com/mksglu/context-mode |
| Caveman plugin | https://github.com/JuliusBrussee/caveman |
| RTK standalone | https://github.com/rtk-ai/rtk |

Restart: `exec $SHELL`. Run `claude` — auto-wraps via Headroom. `/caveman` → compressed output.

## Layer map

```
shell wrapper → headroom wrap claude
  PreToolUse:  bash-ban-raw-tools + cbm-code-discovery-gate + context-mode
  PostToolUse: cbm-mcp-marker + context-mode
  SessionStart: cbm-session-reminder + context-mode
  plugin: caveman (output compression)
  config: CLAUDE.md + rules/*
  RTK: bundled in Headroom, compresses shell output
```
