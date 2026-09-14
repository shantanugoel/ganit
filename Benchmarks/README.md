# Benchmark fixtures

`GanitBenchmarks` is the release-only home for deterministic performance fixtures. In Phase 0 it lists the required fixture targets from `PLAN.md`; it intentionally does not execute an empty engine, invent samples, or report a passing budget.

```sh
swift run --configuration release GanitBenchmarks --list
```

Running the executable without `--list` fails until Phase 1 adds a real expression benchmark. Each later benchmark must:

- use release configuration and an immutable evaluation context;
- use deterministic checked-in or reproducibly generated fixture source;
- record the commit, fixture revision, Mac model, memory, macOS, Xcode, sample count, warmup, P50, and P95;
- keep raw samples or a machine-readable summary outside the production app bundle;
- compare measurements with the budgets in `PLAN.md` without changing a failed gate into a pass;
- avoid timing fixture loading, process launch, or unrelated setup unless that is the named metric.

The seven listed targets are unavailable, not passing. Their corpus population and assertions belong to the phases that implement the corresponding semantics.

Recorded measurements:

- [Phase 0 release baseline](Results/phase-0.md)
- [Phase 1 parser baseline](Results/phase-1-parser.md)
