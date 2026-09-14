# Numeric value invariants

Ganit's engine owns four immutable numeric value types. `BigInt` is an implementation detail of `IntegerValue`; no other module imports or exposes it.

- `IntegerValue` stores an arbitrary-sized signed integer. Direct text conversion accepts at most 10,000 digits before parsing so public callers cannot enter BigInt's quadratic conversion path with unbounded input.
- `RationalValue` stores a reduced numerator and a strictly positive denominator. Zero is always `0/1`.
- `DecimalValue` stores `coefficient × 10⁻ˢᶜᵃˡᵉ`. Scale is structural user intent, so `1.0` and `1.00` are distinct values. Negative scales are valid; `Int.min` is rejected because its magnitude cannot be represented safely.
- `ApproximateValue` stores a finite binary estimate, its source, and explicit precision metadata. It rejects nonfinite estimates, significant-digit claims outside `1...17` for its binary `Double` estimate, and negative absolute error bounds. Seventeen is a representational ceiling for decimal round trips, not a claim that every `Double` contains 17 mathematically accurate digits; each approximate operation remains responsible for supplying honest metadata.

These types do not yet define arithmetic. The next Phase 1 task adds operations and controls exact-to-approximate transitions.

## Errors

`EngineError` carries a stable machine code, severity, zero or more exact source ranges, localization message key, optional fix-its, and typed context that does not contain user source. Low-level value construction can produce an error without a source range; the evaluator will attach expression ranges at its boundary.

Localized explanations belong to `GanitFormatting` and string catalogs. Error codes and English prose are not used as interchangeable identifiers.

## Dependency and persistence

The exact types use the pinned BigInt dependency accepted in [ADR 0003](../adr/0003-numeric-representation.md). The package lock verifies its audited revision, and the application bundle carries the dependency's MIT notice.

Derived numeric values are not authoritative document data, so they do not conform to `Codable`. If persistence becomes necessary, it requires a versioned Ganit-owned encoding rather than exposing the dependency's representation.
