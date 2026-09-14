# Phase 1 engine baseline

- Date: 2026-09-14
- Base commit: `287753d9f6061626b9f84c65f9d39a1e0ce7590d`
- Benchmark implementation diff SHA-256:
  `e4cd204d22caa5624c2dc3e1aab04b6e6c48ccf9afb4a4b96d67f2e07554e2c2`
- Hardware: MacBook Pro (MacBookPro18,2), Apple M1 Max, 10 cores, 32 GB
- System: macOS 26.6 (25G72)
- Toolchain: Xcode 26.5 (17F42), Swift 6.3.2
- Configuration: release, arm64

Command after one release build:

```sh
swift run --configuration release GanitBenchmarks --engine 1000
```

Twenty independent process runs each evaluated 200,000 expressions: 1,000
iterations across 200 distinct, reproducibly generated expressions. The
corpus covers integer, rational, decimal, precedence, power, exact and
approximate roots, programmer literals, variadic functions, implicit
multiplication, constants, trigonometry, and logarithms.

- Fixture FNV-1a 64-bit checksum: `12c96818e2b86450`
- Timed result checksum per process: `2685000`
- P50: 5,675.929 ns (0.005676 ms) per expression
- P95: 5,763.969 ns (0.005764 ms) per expression
- Samples in run order (ns per expression): 5,644.126, 5,645.587, 5,686.475,
  5,694.701, 5,763.969, 5,679.070, 5,765.781, 5,728.261, 5,623.986,
  5,644.016, 5,711.756, 5,654.905, 5,675.929, 5,678.832, 5,645.902,
  5,709.087, 5,667.042, 5,634.747, 5,660.571, 5,688.852

P50 and P95 use nearest-rank percentiles (`ceil(p × 20) - 1` in the sorted,
zero-based sample array). The process runs and aggregation used:

```sh
bin="$(swift build --configuration release --show-bin-path)/GanitBenchmarks"
BIN="$bin" ruby -ropen3 -e '
  samples = 20.times.map do
    output, status = Open3.capture2(ENV.fetch("BIN"), "--engine", "1000")
    abort output unless status.success?
    Float(output[/nanoseconds_per_expression=([0-9.]+)/, 1])
  end
  sorted = samples.sort
  p samples:, p50: sorted[9], p95: sorted[18]
'
```

Each process constructs one immutable evaluation context and one engine, then
evaluates every fixture once before timing and retains those expected values.
The timed interval covers lexing, parsing, AST construction, evaluation, and a
result equality check against the warmed value. It excludes process launch,
context construction, fixture generation, prevalidation, formatting, UI, and
output. Result types and source lengths are consumed into the checksum after
the full numeric equality check.

The observed P95 is below the Section 8 target of 1 ms after initialization on
this current Apple Silicon Mac. It does not by itself pass the release gate,
which also requires measurement on the documented M1 MacBook Air, 8 GB
baseline and the oldest supported macOS.
