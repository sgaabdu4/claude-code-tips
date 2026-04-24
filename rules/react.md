# React/Next.js gate
Invoke `vercel-react-best-practices` skill FIRST.
Self-check:
1. Server Components default. `"use client"` only for interaction
2. Heavy compute (`find()`/`filter()`/`sort()`/tz/O(n) scans) → `useMemo` stable deps. Never in `.map()` callbacks, JSX attrs, render body
3. No `enum` — `as const` objects: `{ FOO: 'foo' } as const`
4. Status variants → `Record<Status, Variant>` map, not ternary chains
