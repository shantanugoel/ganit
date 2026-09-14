# Phase 1 verification

Phase 1's typed arithmetic engine exit criteria were audited on 2026-09-14
against the implementation based on commit
`c98afbc12db77c497e1a9eed0d527acbec93392d` plus the Phase 1 exit fixes.

## Exit criteria

### Exact arithmetic does not implicitly use `Double`

Integer, rational, and decimal literals and ordinary arithmetic remain backed
by `BigInt`. Exact multiplication, decimal alignment, and integral-power
preflights use integer bit-width lower bounds followed by exact result
validation. Floating-point conversion occurs only after an explicitly
approximate operand or mathematically inexact root/transcendental transition.

Evidence includes focused resource-boundary tests, 1,000 seeded differential
cases against native bounded integer arithmetic, 500 seeded power-of-two
boundary cases, and every configured magnitude boundary from 2 through 63
bits.

### Every source-expression failure has code, range, and message

Syntax and evaluation failures retain stable codes, severity, exact source
ranges, optional fix-its, localization keys, and typed context without source
text. `DiagnosticFormatter` resolves concise explanations through the
`GanitFormatting` string catalog. The internal JSON-lines harness preserves
all syntax diagnostics and attaches the full expression range to formatting
failures. Low-level value/context constructor errors can be source-less; the
evaluator attaches ranges whenever they arise from an expression.

The production app builder compiles and embeds the formatting string catalog,
and the bundle verifier checks the compiled localization resource.

### Exact versus approximate output is inspectable

`NumericValue` uses distinct exact and approximate cases.
`ApproximationPrecision` and `ApproximationSource` retain approximation
metadata. `FormattedResult` exposes localized display, canonical full
precision, and `isApproximate`; approximate strings remain marked with `≈`.

### Corpus and fuzz smoke pass under supported sanitizers

The deterministic golden, arithmetic property, native differential,
numeric-boundary, and malformed-Unicode parser suites pass under Address
Sanitizer. CI runs the same filtered sanitizer command.

## Verification commands

```sh
./scripts/swift-format.sh lint
swift package dump-package
swift test --parallel
swift test --sanitize address \
  --filter 'GoldenCorpusTests|ArithmeticPropertyTests|ParserFuzzSmokeTests'
swift run --configuration release GanitBenchmarks --list
swift run --configuration release GanitBenchmarks --parser 1000
swift run --configuration release GanitBenchmarks --engine 10
./scripts/build-app.sh release
./scripts/verify-app.sh
```

Local results:

- 75 tests passed.
- 8 corpus/property/fuzz tests passed under Address Sanitizer.
- The release app bundle passed architecture, signing, sandbox, privacy,
  third-party notice, and compiled diagnostic-localization checks.
- The remeasured 200-expression initialized-engine baseline reports a median
  run P50 of 0.004500 ms, median run P95 of 0.013542 ms, and highest run P95
  of 0.013750 ms on the documented M1 Max system.

The engine measurement is below the 1 ms target on this current Apple Silicon
Mac. It does not claim the release gate on the still-required M1 MacBook Air,
8 GB and oldest-supported-macOS matrix. Statistical CI regression thresholds
also remain a later performance-infrastructure gate.
