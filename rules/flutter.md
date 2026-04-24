# Flutter/Dart gate — NON-NEGOTIABLE
Invoke `building-flutter-apps` skill FIRST. No skip.
Self-check:
1. `if (!ref.mounted) return;` after every `await` in notifier
2. `if (!context.mounted) return;` after every `await` in widget/State. Never bare `mounted`. Lint fires → extract sync helper on State w/ `this.context` (no `BuildContext` arg)
3. No `_buildXxx()` — extract widget classes
4. No hardcoded strings — `*Strings` constants
5. `ref.watch` in build, `ref.read` in callbacks only
6. Riverpod 3.x codegen: `FooNotifier` → `fooProvider`
7. No `shrinkWrap: true` on ListView/GridView
Run skill Pre-Flight before return.
