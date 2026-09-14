# Phase 1 engine baseline

- Date: 2026-09-14
- Base commit: `c98afbc12db77c497e1a9eed0d527acbec93392d`
- Benchmark implementation diff SHA-256:
  `88004fbbd0192cbdda76dbc93d431a562fd92765d2ac1a09f096ff13f473a79f`
- Measured engine implementation diff SHA-256:
  `60546e946469aa347137d0cebfa4be681d22909e3e532d39db4f93d57f3eb20a`
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
- Median run average: 5,814.014 ns (0.005814 ms) per expression
- Median run P50: 4,500 ns (0.004500 ms) per expression
- Median run P95: 13,542 ns (0.013542 ms) per expression
- Highest run P95: 13,750 ns (0.013750 ms) per expression
- Samples in run order as average/P50/P95 nanoseconds:
  6,002.197/4,541/13,625, 5,825.621/4,542/13,542,
  5,819.130/4,500/13,542, 5,791.338/4,500/13,500,
  5,955.618/4,625/13,708, 5,778.574/4,500/13,542,
  5,771.941/4,500/13,500, 5,812.438/4,500/13,584,
  5,817.304/4,500/13,541, 5,791.410/4,500/13,500,
  5,779.219/4,500/13,500, 5,814.014/4,541/13,542,
  5,812.270/4,500/13,542, 5,894.938/4,583/13,583,
  5,912.296/4,625/13,750, 5,775.292/4,500/13,500,
  5,795.881/4,500/13,542, 5,823.754/4,542/13,583,
  5,832.855/4,541/13,584, 5,814.694/4,541/13,542

Each run's P50 and P95 are nearest-rank percentiles over its 200,000
individual expression latency samples. The reported median values are the
lower nearest-rank medians (`sorted[9]`) of the 20 run-level statistics. The
process runs and aggregation used:

```sh
bin="$(swift build --configuration release --show-bin-path)/GanitBenchmarks"
BIN="$bin" ruby -ropen3 -e '
  runs = 20.times.map do
    output, status = Open3.capture2(ENV.fetch("BIN"), "--engine", "1000")
    abort output unless status.success?
    {
      average: Float(output[/nanoseconds_per_expression=([0-9.]+)/, 1]),
      p50: Float(output[/p50_nanoseconds=([0-9.]+)/, 1]),
      p95: Float(output[/p95_nanoseconds=([0-9.]+)/, 1])
    }
  end
  median = ->(key) { runs.map { |run| run.fetch(key) }.sort[9] }
  p runs:, median_average: median.call(:average),
    median_p50: median.call(:p50), median_p95: median.call(:p95),
    maximum_p95: runs.map { |run| run.fetch(:p95) }.max
'
```

Each process constructs one immutable evaluation context and one engine, then
evaluates every fixture once before timing and retains those expected values.
Each individual sample covers clock reads, lexing, parsing, AST construction,
evaluation, and a result equality check against the warmed value. The
whole-run average additionally includes appending samples to a preallocated
array; percentile sorting occurs after the timed interval. Measurements
exclude process launch, context construction, fixture generation,
prevalidation, formatting, UI, and output. Result types and source lengths are
consumed into the checksum after the full numeric equality check.

Every observed per-expression P95 is below the Section 8 target of 1 ms after
initialization on this current Apple Silicon Mac. This does not by itself pass
the release gate, which also requires measurement on the documented M1
MacBook Air, 8 GB baseline and the oldest supported macOS.
