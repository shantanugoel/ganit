# Contributing to Ganit

Ganit is currently developed against the ordered roadmap and quality gates in [`PLAN.md`](PLAN.md). Discuss changes that alter product scope, language semantics, storage formats, dependencies, privacy, or platform support before implementation, and capture lasting decisions in an architecture decision record.

## Requirements

- macOS 14 or later
- A current stable Xcode with the Swift 6 toolchain
- Command Line Tools selected with `xcode-select`
- Git

No additional formatter, linter, package manager, or global tool is required unless the repository pins it.

## Working agreement

1. Work on one unchecked `PLAN.md` task at a time and preserve phase boundaries.
2. Restate the task's relevant exit criteria and resolve decisions that would fork the implementation.
3. Add focused failing tests or an honest benchmark before production code where practical.
4. Implement the smallest complete vertical slice using DRY, YAGNI, and KISS.
5. Do not add backward-compatibility code, speculative abstraction, or a second parser/evaluator path.
6. Run focused checks, then all available package and app checks.
7. Review the final diff for correctness, simplicity, accessibility, privacy, durability, and resource regressions.
8. Commit and push the completed task before beginning another task.

## Build and test

The repository does not contain buildable targets yet. The Phase 0 package-skeleton task will add and verify the canonical build and test commands. Until then, documentation-only changes must pass:

```sh
git diff --check
```

Once the package skeleton lands, this section must be updated in the same task with commands that work from a clean checkout. Do not claim sanitizer, performance, accessibility, or release-matrix coverage unless that coverage was actually run and recorded.

## Engineering expectations

- Use Swift 6 language mode and adopt strict concurrency per module.
- Keep `GanitEngine` deterministic and independent of AppKit, storage, networking, global clocks, and singleton locale state.
- Keep user source authoritative; formatters do not reparse it and UI code does not calculate.
- Preserve exact source ranges and typed errors for every failed expression.
- Use standard AppKit components and responder-chain behavior for user-facing Mac UI.
- Localize user-visible and accessibility strings from their first introduction.
- Never log or transmit expression or sheet text.
- Justify and pin every dependency. Prefer platform frameworks and repository-owned focused code.
- Avoid polling, hidden coercion, silent guesses, and unbounded storage or cache growth.

## Commits

Keep each commit scoped to one plan task. Include updated tests, documentation, decision records, benchmark evidence, and checklist state required by that task. Do not commit generated build products, local settings, secrets, or scratch reports.
