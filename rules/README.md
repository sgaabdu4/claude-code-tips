# Stack rules — drop your own here

Files in `~/.claude/rules/<stack>.md` are skill-gated checklists Claude reads before touching code in that stack. Frontmatter `paths:` scopes a rule to matching files (matches across **every project on this machine** — the rule fires whenever Claude opens a matching file, regardless of repo); without `paths:`, the rule loads globally for any project. Each rule starts with `Invoke <skill-name> FIRST` — that's the load-bearing line.

A **skill** is a Markdown file at `~/.claude/skills/<name>/SKILL.md` (or installed by a plugin under `~/.claude/plugins/cache/<plugin>/<plugin>/<hash>/skills/<name>/`). To discover what's available, browse `~/.claude/skills/` directly (`ls ~/.claude/skills`) or ask Claude "find a skill for X" — that auto-triggers the `find-skills` skill. The skill name in your rule must match a real skill name exactly; a typo or missing skill = the `Invoke` line does nothing, but the numbered self-check below still fires. So if no skill matches your stack, the rule still earns its keep — just keep the checklist focused.

The repo ships **empty** (just this README). Stack rules are project-specific — backend rules look nothing like react rules. Listing mine in the install would either pollute your context with stuff you don't ship, or imply they apply when they don't.

## Quick start — fork this template

Save as `rules/<stack>.md` in this repo, run `./install.sh` to copy it to `~/.claude/rules/`. Or write directly to `~/.claude/rules/<stack>.md`.

```markdown
---
paths:
  - "**/*.<ext>"          # ** is recursive — **/*.py matches src/a.py and src/sub/b.py
  - "**/<config-file>"
---
# <Stack> gate
Invoke `<skill-name>` skill FIRST. No skip.

Self-check before returning:
1. <footgun #1 — concrete, file:line style if you can>
2. <footgun #2>
3. <footgun #3>
4. <...stop at 7. If you have more, you're documenting; this is a checklist>
```

The first body line after the frontmatter MUST be `Invoke <skill-name> FIRST` — Claude reads that line as the routing directive. A heading or comment above it breaks the gate.

### Worked example — TypeScript

```markdown
---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/tsconfig*.json"
---
# TypeScript gate
Invoke `typescript-expert` skill FIRST. No skip.

Self-check before returning:
1. No `any` — use `unknown` then narrow, or write the proper type
2. No `as` casts unless commenting why the runtime guarantees the cast
3. No `enum` — use `as const` objects: `const Status = { OPEN: 'open' } as const`
4. Discriminated unions for state, never optional fields that are sometimes-set
5. `import type { Foo }` for type-only imports so they get stripped at runtime
```

`typescript-expert` here is illustrative — substitute whatever skill matches your stack. Skill names are local to your Claude Code setup and installed plugins. If you write a rule for a stack with no matching skill, keep the same shape but drop the `Invoke` line — the numbered self-check is what does the actual work, the skill routing is just the fast-path when one exists.

## Private examples

The [Medium post](../claude-code-tips.md#per-language-rule-files) shows personal examples to explain the pattern. They are not shipped here. Copy the *structure*, then write your own checks from the failures Claude actually trips on in your codebase.

## Why a numbered checklist beats prose

Claude reads numbered lists as a routine to execute. "Always check mounted" gets ignored. "1. `if (!ref.mounted) return;` after every `await`" gets ticked off. Keep items concrete — paste the exact line of code you want, not a description of it.

## Which line is load-bearing?

If a matching skill exists for your stack, the `Invoke <skill> FIRST` line is the fast-path — it routes Claude to a curated skill before anything else. If no skill matches, the numbered self-check is what does the work — Claude reads the list as a routine to execute. Either way, the **rule file as a whole is what fires** when one of your `paths:` globs matches. Don't ship an empty rule (it does nothing); do ship one with at least the checklist or the skill route, ideally both.
