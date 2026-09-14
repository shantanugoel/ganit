# Contributing to Ganit

Ganit is currently developed against the ordered roadmap and quality gates in [`PLAN.md`](PLAN.md). Discuss changes that alter product scope, language semantics, storage formats, dependencies, privacy, or platform support before implementation, and capture lasting decisions in an architecture decision record.

## Requirements

- macOS 14 or later
- The Xcode version recorded in `.xcode-version`
- Command Line Tools selected with `xcode-select`
- Git

No additional formatter, linter, package manager, or global tool is required. The formatting script verifies and uses the `swift-format` bundled with the pinned Xcode.

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

Resolve the package manifest and build every product:

```sh
swift package dump-package >/dev/null
swift build
```

Run all package tests, including the engine without launching the app:

```sh
swift test
```

Build the arm64 application bundle and launch the Phase 0 AppKit window:

```sh
./scripts/build-app.sh debug
./scripts/verify-app.sh .build/app/debug/Ganit.app
open .build/app/debug/Ganit.app
```

Documentation-only changes must also pass `git diff --check`. Do not claim sanitizer, performance, accessibility, or release-matrix coverage unless that coverage was actually run and recorded.

## Formatting

Format all Swift sources and the package manifest:

```sh
./scripts/swift-format.sh format
```

Check formatting without changing files:

```sh
./scripts/swift-format.sh lint
```

The script rejects an unpinned Xcode or `swift-format` version so local and CI output remains deterministic.

## Benchmarks

List the required benchmark fixture targets:

```sh
swift run --configuration release GanitBenchmarks --list
swift run --configuration release GanitBenchmarks --parser 10000
swift run --configuration release GanitBenchmarks --engine 1000
```

The Phase 1 launch-expression fixture is available; later-phase fixtures
remain unavailable until their implementing phases populate them. The
microbenchmarks record observations without applying a pass threshold. Follow
the measurement rules in [`Benchmarks/README.md`](Benchmarks/README.md).

Measure process start to a visible Workspace window after building the release app:

```sh
./scripts/measure-launch.sh 20
```

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
