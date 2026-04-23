# React/Next.js gate
Invoke `vercel-react-best-practices` skill FIRST.
Self-check:
1. Server Components default. `"use client"` only for interaction
2. Heavy compute → `useMemo` w/ stable deps. Never in `.map()` callbacks
3. No `enum` — `as const` objects
4. Status variants → `Record<Status, Variant>` map, not ternary chains
