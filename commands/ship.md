---
name: ship
description: Plan-refine-implement feature. Parallel-agent discovery → synthesized plan → user-gated refine loop → spawn `claude` CLI subprocesses per worktree → auto-merge into current branch on green tests.
argument-hint: "<feature description> (e.g. /ship add OAuth login w/ Google + GitHub)"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Agent, Task, AskUserQuestion, advisor, mcp__codebase-memory-mcp__index_repository, mcp__codebase-memory-mcp__index_status, mcp__codebase-memory-mcp__detect_changes, mcp__codebase-memory-mcp__get_architecture, mcp__codebase-memory-mcp__search_graph, mcp__codebase-memory-mcp__trace_path, mcp__codebase-memory-mcp__search_code, mcp__plugin_context-mode_context-mode__ctx_batch_execute, mcp__plugin_context-mode_context-mode__ctx_execute, Monitor]
---

# /ship — feature pipeline

Build feature: **$ARGUMENTS**

Five phases. Each phase = recovery point. STOP between phases on fail.

---

## Phase 0 — Bootstrap

1. `index_status`. Unindexed → `index_repository`. Else `detect_changes`.
2. `get_architecture` → stack detect (django|vue|python|node|other).
3. Detect build/test tooling — **detect installed commands, don't hardcode**:
   - **Python/Django**: scan `pyproject.toml` / `setup.cfg` / `tox.ini` / `requirements*.txt` / `manage.py`.
     - TEST_CMD: `pytest` if `pytest`/`pytest-django` in deps OR `[tool.pytest.ini_options]` present; else `python manage.py test`.
     - LINT_CMD: `ruff check .` if `ruff` present; else `flake8`.
     - TYPECHECK_CMD: `mypy .` if `mypy` present; else skip + note gap in plan.
   - **Vue/JS**: scan `package.json` scripts + devDependencies.
     - TEST_CMD: `npm run test` (vitest/jest per devDeps).
     - LINT_CMD: `npm run lint` (eslint) if script exists; else `npx eslint .`.
     - TYPECHECK_CMD: `vue-tsc --noEmit` if `vue-tsc` present; else `npm run typecheck` if script exists; else skip + note gap.
   Save:
   ```
   STACK=<name>
   TEST_CMD=<cmd>
   LINT_CMD=<cmd>
   TYPECHECK_CMD=<cmd>
   ```
4. Confirm clean tree. Dirty → STOP, ask user commit/stash.
5. **Capture base branch** (merge target):
   ```bash
   BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
   ```
   Branch user invoke `/ship` from. ALL merges target this, NOT `main`. If `BASE_BRANCH` = `main` or default-protected, warn + ask confirm.

---

## Phase 1 — Discovery (parallel agents)

Spawn parallel (single message, multi Agent calls). Each agent self-contained, return <200 words:

**Always:**
- `Explore` — current arch + existing patterns for $ARGUMENTS
- `edge-case-hunter` — edges/ripple/boundary for feature
- `reuse-auditor` — existing components/utilities reuse, no DRY violation
- `staff-engineer` — arch fit, tradeoffs, abstractions to avoid
- `qa-engineer` — test plan: happy + fail + edge per task

**Stack-conditional (only if detected and installed locally):**
- django/python backend → `django-auditor`
- vue frontend → `vue-auditor`
- web ui → `web-ui-auditor`, `ux-reviewer`
- security-sensitive (auth/payment/PII) → `security-reviewer`

If a local subagent type is missing, skip it and note the gap in the plan.

**Cap parallel = 5.** Batch waves of 5 if more.

Collect reports → context.

---

## Phase 2 — Synthesis

Write `docs/ship-plan.md`. Strict markdown:

```markdown
# Ship Plan: <feature title>

## Spec
<1 paragraph — what + why>

## Constraints
- <verbatim user rules + tech constraints from Phase 1>

## Edge cases
- <from edge-case-hunter, must-handle list>

## Tasks (worktree partition)
Each task = one worktree.

### task-1: <name>
- branch: `ship/<feat>/task-1-<slug>`
- exclusive_files: [paths only this task writes]
- shared_files: [paths multiple tasks may append/register to — e.g. routes.ts, di.ts, exports]
- depends_on: []  # task IDs that must merge first
- spec: <2-3 sentences>
- tests: <test files + cases>
- acceptance: <green tests + lint + typecheck>

### task-2: <name>
... same structure ...

## Merge order
Topological by `depends_on`. Plus: any two tasks listing the same `shared_files` entry MUST be in different waves (serialized, no parallel writes to same file).

## Test plan
- per-task acceptance above
- post-merge integration smoke: <cmd>
```

**Validation before save:**
- `exclusive_files` cross-check: no two tasks share `exclusive_files` entry. Conflict → re-partition.
- `shared_files` allowed across tasks BUT scheduled different waves.
- Each task has tests defined.
- Topological-sort `depends_on`. Cycle → fail, ask user.
- Compute **dispatch waves**: wave[N] = tasks where all `depends_on` in waves <N AND no two tasks in wave[N] share any `shared_files` entry. Save wave assignment in plan.

`advisor()` — review plan before user gate.

---

## Phase 3 — Refine loop (user-gated)

Show user `docs/ship-plan.md` summary + advisor notes.

`AskUserQuestion`:
- **Approve** → Phase 4
- **Refine** → user free-text feedback → re-spawn relevant agents w/ feedback → update `ship-plan.md` → re-advisor → loop
- **Abort** → delete plan, STOP

No iter cap. User decide done.

---

## Phase 4 — Worktree dispatch (wave-by-wave)

Process waves **serially**. Within each wave, tasks **parallel, cap 3 concurrent**. Wave N+1 only start after wave N fully merged into `$BASE_BRANCH` (Phase 5 gate per wave).

For each task in current wave:

1. **Create worktree from latest `$BASE_BRANCH`:**
   ```bash
   git fetch origin "$BASE_BRANCH" 2>/dev/null || true   # local-only branch ok
   git worktree add .claude/worktrees/ship-<task-id> \
     -b ship/<feat>/task-<id> "$BASE_BRANCH"
   ```
   (Branch from local `$BASE_BRANCH` HEAD = wave-N+1 worktrees see merged wave-N code.)

2. **Write task brief** `.claude/worktrees/ship-<task-id>/TASK.md`:
   - copy task block from plan (incl. `exclusive_files`, `shared_files`)
   - inline test/lint/typecheck cmds (fully expanded, NOT `$VAR` — claude subprocess no expand parent shell vars)
   - rule: "Write only files in `exclusive_files` + `shared_files`. For `shared_files`, append/register only — do not rewrite peers' sections."

3. **Spawn `claude` CLI subprocess** (background, per worktree, isolated session):
   ```bash
   cd .claude/worktrees/ship-<task-id> && \
   claude -p "$(cat TASK.md)

   Procedure:
   1. Read ../../docs/ship-plan.md for full context
   2. TDD: write failing tests first, then implement
   3. Run inlined test+lint+typecheck cmds from TASK.md
   4. All green → git add + git commit -m 'ship/<feat> task-<id>: <subject>'
   5. Stop. Final line: 'DONE' or 'BLOCKED: <reason>'" \
     --permission-mode bypassPermissions \
     --allow-dangerously-skip-permissions \
     --output-format stream-json \
     --no-session-persistence \
     > .claude/worktrees/ship-<task-id>/.claude-output \
     2> .claude/worktrees/ship-<task-id>/.claude-error &
   echo $! > .claude/worktrees/ship-<task-id>/.pid
   ```
   Use Bash `run_in_background: true`.

   `bypassPermissions` + `--allow-dangerously-skip-permissions` required for unattended writes/bash. Safe: subprocess sandboxed to worktree dir, no outside reach.

4. **Monitor — one Monitor call per worktree** (glob `tail -f` skip later worktrees; do not use):
   ```bash
   # one persistent Monitor per task at spawn time:
   tail -f .claude/worktrees/ship-<task-id>/.claude-output | \
     grep --line-buffered -E "^DONE$|^BLOCKED|Traceback|Error|FAILED|Killed"
   ```

5. Wait for ALL subprocesses in wave exit. Trigger Phase 5 gate for wave.

---

## Phase 5 — Auto-merge gate (per wave)

After all subprocesses in wave exit, process each completed worktree (intra-wave order arbitrary; deps satisfied by wave assignment):

```bash
cd .claude/worktrees/ship-<task-id>
$TEST_CMD && $LINT_CMD && $TYPECHECK_CMD
```

**All green:**
1. Inside worktree: `git rebase "$BASE_BRANCH"` (conflict → BLOCK, hand to user)
2. Switch base in main checkout: `git -C <repo-root> checkout "$BASE_BRANCH"`
3. Fast-forward merge: `git -C <repo-root> merge --ff-only ship/<feat>/task-<id>`
4. **No push.** Local merge only — user push when ready.
5. `git worktree remove .claude/worktrees/ship-<task-id>`
6. `git branch -d ship/<feat>/task-<id>`

**Any red OR conflict:**
- Keep worktree
- Log to `docs/ship-report.md` w/ failure detail
- Continue other independent tasks
- Final report lists held worktrees + reasons

---

## Final report

Write `docs/ship-report.md`:
- merged tasks (commit SHAs)
- held tasks (worktree path + failure reason + suggested next step)
- post-merge smoke test result

Push notification: `feature shipped: N/M tasks merged`.

---

## Safety rules

- **Never auto-merge** if `$BASE_BRANCH` diverged mid-run (HEAD moved by external actor)
- **Never push** anywhere. User decide when + where.
- **Never force-push**. Never `--no-verify` any hook.
- **Never target `main`/protected** unless user invoke `/ship` from it AND confirm warning
- **Stop hard** on dirty tree at start, partition collision, dep cycle
- **User gate** mandatory between Phase 2 plan + Phase 4 dispatch
- **Worktree isolation** = files-disjoint enforced at plan time, not just runtime
- **Subprocess output** captured to file, never piped raw to context

---

## Failure recovery

| Phase | Fail mode | Recovery |
|---|---|---|
| 0 | dirty tree | ask user commit/stash |
| 1 | agent error | retry once, else skip + note in plan |
| 2 | partition collision | re-spawn staff-engineer w/ collision report |
| 3 | user abort | delete plan, exit clean |
| 4 | subprocess BLOCKED | hold worktree, continue independent peers |
| 5 | tests red | hold worktree, full report at end |
| 5 | merge conflict | hold worktree, hand to user, no force |
