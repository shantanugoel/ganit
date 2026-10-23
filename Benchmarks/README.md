# Benchmark fixtures

`GanitBenchmarks` is the release-only home for deterministic performance fixtures. In Phase 0 it lists the required fixture targets from `PLAN.md`; it intentionally does not execute an empty engine, invent samples, or report a passing budget.

Use the native SwiftPM backend for release measurements. The release app uses
the same backend. On the pinned Xcode 27 toolchain, the default backend fails
the dependency editor limit on the test Mac. The native backend passes it.
See the [M5 verification record](../docs/quality/ai-native-m5.md).

```sh
swift run --build-system native --configuration release GanitBenchmarks --list
```

Run the Phase 1 parser-only and initialized engine benchmarks with:

```sh
swift run --build-system native --configuration release GanitBenchmarks --parser 10000
swift run --build-system native --configuration release GanitBenchmarks --engine 1000
```

Each benchmark must:

- use release configuration and an immutable evaluation context;
- use deterministic checked-in or reproducibly generated fixture source;
- record the commit, fixture revision, Mac model, memory, macOS, Xcode, sample count, warmup, P50, and P95;
- keep raw samples or a machine-readable summary outside the production app bundle;
- compare measurements with the budgets in `PLAN.md` without changing a failed gate into a pass;
- avoid timing fixture loading, process launch, or unrelated setup unless that is the named metric.

Run the Phase 3 incremental sheet benchmarks with:

```sh
swift run --build-system native --configuration release GanitBenchmarks --sheet mixed-sheet 500
swift run --build-system native --configuration release GanitBenchmarks --sheet independent-sheet 500
swift run --build-system native --configuration release GanitBenchmarks --sheet chained-dependency-sheet 500
```

Run the Phase 4 editor edit-to-answer benchmarks, which drive the real sheet
editor offscreen, with:

```sh
swift run --build-system native --configuration release GanitBenchmarks --editor mixed-sheet 200
swift run --build-system native --configuration release GanitBenchmarks --editor chained-dependency-sheet 200
```

Run the same editor measurements while another document waits for an Ask reply:

```sh
swift run --build-system native --configuration release GanitBenchmarks --editor-active-ask mixed-sheet 200
swift run --build-system native --configuration release GanitBenchmarks --editor-active-ask chained-dependency-sheet 200
```

This mode uses the real Ask coordinator and an injected provider that keeps one
request pending. The Ask uses a frozen source snapshot in a separate synthetic
document. It does not read provider preferences or the keychain. It sends no
network request. The coordinator clock is fixed so the request cannot time out
during a long run. Each edit uses the same source change and time interval as
`--editor`. The mode checks that one request stays pending for all edits, then
cancels it. Output records these checks. This check covers a pending provider.
It does not measure candidate checking or repair CPU work.

Run the table edit benchmark, which alternates one table cell source edit and
one prose edit of a table reader through the incremental calculator, with:

```sh
swift run --build-system native --configuration release GanitBenchmarks --table 200
```

Measure Quick Ganit's cold launch, idle memory, and resident show path with:

```sh
./scripts/measure-quick.sh 20
swift run --build-system native --configuration release GanitBenchmarks --quick 200
```

The sheet fixtures live in `Fixtures/`; `SheetFixtureTests` uses the same files
to assert which lines each edit re-evaluates.

The `launch-expressions` target is available in Phase 1, the three sheet
targets in Phase 3, and the `table-sheet` target since M6 of the tables plan.
The remaining targets stay unavailable, not passing; their corpus population
and assertions belong to the phases that implement the corresponding
semantics.

Recorded measurements:

- [Phase 0 release baseline](Results/phase-0.md)
- [Phase 1 parser baseline](Results/phase-1-parser.md)
- [Phase 1 engine baseline](Results/phase-1-engine.md)
- [Phase 3 incremental sheet baseline](Results/phase-3-sheets.md)
- [Phase 4 edit-to-answer baseline](Results/phase-4-editor.md)
- [Phase 6 Quick Ganit invocation baseline](Results/phase-6-quick.md)
