# Benchmark fixtures

`GanitBenchmarks` is the release-only home for deterministic performance fixtures. In Phase 0 it lists the required fixture targets from `PLAN.md`; it intentionally does not execute an empty engine, invent samples, or report a passing budget.

```sh
swift run --configuration release GanitBenchmarks --list
```

Run the Phase 1 parser-only and initialized engine benchmarks with:

```sh
swift run --configuration release GanitBenchmarks --parser 10000
swift run --configuration release GanitBenchmarks --engine 1000
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
swift run --configuration release GanitBenchmarks --sheet mixed-sheet 500
swift run --configuration release GanitBenchmarks --sheet independent-sheet 500
swift run --configuration release GanitBenchmarks --sheet chained-dependency-sheet 500
```

Run the Phase 4 editor edit-to-answer benchmarks, which drive the real sheet
editor offscreen, with:

```sh
swift run --configuration release GanitBenchmarks --editor mixed-sheet 200
swift run --configuration release GanitBenchmarks --editor chained-dependency-sheet 200
```

Measure Quick Ganit's cold launch, idle memory, and resident show path with:

```sh
./scripts/measure-quick.sh 20
swift run --configuration release GanitBenchmarks --quick 200
```

The sheet fixtures live in `Fixtures/`; `SheetFixtureTests` uses the same files
to assert which lines each edit re-evaluates.

The `launch-expressions` target is available in Phase 1 and the three sheet
targets in Phase 3. The other three targets remain unavailable, not passing;
their corpus population and assertions belong to the phases that implement the
corresponding semantics.

Recorded measurements:

- [Phase 0 release baseline](Results/phase-0.md)
- [Phase 1 parser baseline](Results/phase-1-parser.md)
- [Phase 1 engine baseline](Results/phase-1-engine.md)
- [Phase 3 incremental sheet baseline](Results/phase-3-sheets.md)
- [Phase 4 edit-to-answer baseline](Results/phase-4-editor.md)
- [Phase 6 Quick Ganit invocation baseline](Results/phase-6-quick.md)
