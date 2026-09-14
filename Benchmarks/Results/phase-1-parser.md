# Phase 1 parser baseline

- Date: 2026-09-14
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB
- System: macOS 26.6 (25G72)
- Toolchain: Xcode 26.5 (17F42), Swift 6.3.2
- Configuration: release, arm64

Command after one release build:

```sh
swift run --configuration release GanitBenchmarks --parser 10000
```

Ten independent process runs each parsed 100,000 expressions across ten fixed arithmetic syntax fixtures.

- Fixture source SHA-256: `39ab98700e880fdee1e85f005412f079f7816f30554707dd03ff7d056a3556a0`
- P50: 2,920.794 ns per expression
- P95: 3,230.569 ns per expression
- Samples in run order (ns per expression): 3,102.193, 2,913.309, 2,919.939, 2,931.867, 2,896.364, 2,920.794, 2,918.167, 2,934.153, 2,922.808, 3,230.569

Before each timed run, the harness parses every fixture once and validates that it has no diagnostics. Timed iterations consume AST ranges into a checksum. The measurement covers lexing and parsing only, with a warm filesystem and no evaluator, formatter, dependency graph, or UI. These observations establish a regression baseline; they do not prove the Phase 1 simple-evaluation or Section 8 release gate.
