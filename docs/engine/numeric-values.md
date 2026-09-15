# Numeric value invariants

Ganit's engine owns four immutable numeric value types. `BigInt` is an implementation detail of `IntegerValue`; no other module imports or exposes it.

- `IntegerValue` stores an arbitrary-sized signed integer. Direct text conversion accepts at most 10,000 digits before parsing so public callers cannot enter BigInt's quadratic conversion path with unbounded input.
- `RationalValue` stores a reduced numerator and a strictly positive denominator. Zero is always `0/1`. It also produces the nearest decimal at a requested number of significant digits, so presentation can round a fraction without the formatting layer doing arithmetic; see [result formatting](result-formatting.md).
- `DecimalValue` stores `coefficient × 10⁻ˢᶜᵃˡᵉ`. Scale is structural user intent, so `1.0` and `1.00` are distinct values. Negative scales are valid; `Int.min` is rejected because its magnitude cannot be represented safely.
- `ApproximateValue` stores a finite binary estimate, its source, and explicit precision metadata. It rejects nonfinite estimates, significant-digit claims outside `1...17` for its binary `Double` estimate, and negative absolute error bounds. Seventeen is a representational ceiling for decimal round trips, not a claim that every `Double` contains 17 mathematically accurate digits; each approximate operation remains responsible for supplying honest metadata.

`NumericValue` tags these representations. Arithmetic follows one centralized promotion policy:

- integer addition, subtraction, and multiplication remain integer;
- integer division returns an integer when evenly divisible and a reduced rational otherwise;
- decimal addition/subtraction aligns to the larger source scale, and decimal multiplication adds scales;
- exact division involving decimals returns a minimal finite decimal when possible and a rational otherwise;
- a rational operand promotes other exact operands to rational arithmetic;
- an approximate operand produces an approximate result, never an unmarked exact value.

Integral powers remain exact within evaluation limits, including exact reciprocals for negative exponents. Rational powers first attempt bounded exact roots and cross to `Double` only when the result is not exact. Approximation conversion rejects overflow, nonfinite results, and nonzero underflow.

## Functions

The evaluator supports `abs`, `min`, `max`, `round`, `floor`, `ceil`, `sqrt`, and `root`, plus `π`/`pi` and `e`. Exact roots stay exact. `round` uses the rule injected through `EvaluationContext`; trigonometric/logarithmic functions use the same context's angle and precision settings.

Evaluation limits bound visited operations, integer bit width, decimal scale, power exponents, root degrees, and function arguments. Limits are checked before potentially large powers or multiplications and again on produced values.
Exact-operation preflights use integer bit-width bounds, not floating-point
estimates. Ambiguous one-bit boundary cases are evaluated within a bounded
allocation and then checked exactly, so a conservative estimate does not
reject a valid exact result.

## Errors

`EngineError` carries a stable machine code, severity, zero or more exact source ranges, localization message key, optional fix-its, and typed context that does not contain user source. Low-level value construction can produce an error without a source range; every source-expression failure receives one or more ranges at the evaluator boundary.

Localized explanations belong to `GanitFormatting` and string catalogs. Error codes and English prose are not used as interchangeable identifiers.

## Dependency and persistence

The exact types use the pinned BigInt dependency accepted in [ADR 0003](../adr/0003-numeric-representation.md). The package lock verifies its audited revision, and the application bundle carries the dependency's MIT notice.

Derived numeric values are not authoritative document data, so they do not conform to `Codable`. If persistence becomes necessary, it requires a versioned Ganit-owned encoding rather than exposing the dependency's representation.
