# Engine verification corpora

Phase 1 adds three deterministic layers beyond focused unit tests:

- `phase-1-golden.json` fixes representative parse, evaluation, formatting,
  approximation, error code, message key, and source-range outcomes.
- `phase-2-percentages.json`, `phase-2-conversions.json`, and
  `phase-2-ambiguities.json` pin percentage, conversion, and
  [ambiguity registry](../docs/grammar/ambiguity-registry.md) outcomes in the
  same format.
- `ArithmeticPropertyTests` checks exact arithmetic identities, whitespace
  invariance, canonical-format round trips, differential results against
  native bounded integer arithmetic, and numeric bit-limit boundaries with
  fixed PRNG seeds.
- `UnitPropertyTests` checks seeded exact round trips, conversion
  composition, dimensional addition, compound products/powers, family-wide
  incompatible-dimension failures, and affine temperature round trips.
- `parser-fuzz-seeds.json` plus `ParserFuzzSmokeTests` exercises malformed and
  mixed-script Unicode input, generated from a fixed seed under strict syntax
  limits. Every diagnostic range is checked against the original source.

Run these suites directly:

```sh
swift test --filter GoldenCorpusTests
swift test --filter ArithmeticPropertyTests
swift test --filter ParserFuzzSmokeTests
swift test --sanitize address \
  --filter 'GoldenCorpusTests|ArithmeticPropertyTests|ParserFuzzSmokeTests'
```

The golden corpus has schema version `1`. Change an expected outcome only when
an intentional semantics change has been reviewed; add a regression case for
every fixed parser or evaluator bug. Fuzz failures must become permanent seed
entries before the fix is committed.

## Internal command-line harness

`GanitEngineHarness` runs the same engine and formatter used by the app with a
fixed UTC clock, Gregorian calendar, `en-US` locale, radians, and 15-digit
precision. Pass each expression as one quoted argument, or provide one
expression per standard-input line:

```sh
swift run GanitEngineHarness "1 + 2 * 3" "sqrt(2)"
printf '1 / 3\n1 / 0\n' | swift run GanitEngineHarness
```

It emits one sorted-key JSON object per expression. Successful records include
localized display, canonical full precision, and approximation state.
Failures include a stable code, localization message key, and the first source
range. The harness is internal verification tooling, not a supported user CLI.
