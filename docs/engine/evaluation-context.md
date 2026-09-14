# Evaluation context

Every source evaluation requires one immutable `EvaluationContext`. The engine never reads `Locale.current`, `Calendar.current`, `TimeZone.current`, or the system clock.

The context carries:

- a persisted BCP 47 locale identifier and its explicit decimal/grouping syntax;
- radians or degrees for trigonometric input and inverse-trigonometric output;
- requested significant decimal digits and a rounding rule;
- one frozen `Date` used as `now` for the whole evaluation generation;
- a concrete Foundation calendar value;
- a concrete Foundation time-zone value, also applied to the calendar.

`CalculationEngine` passes the locale syntax to parsing and the same context to evaluation. This makes `1,5` deterministic in a comma-decimal sheet and prevents settings or system preference changes during one generation.

Construction rejects an empty locale identifier, a nonfinite date, and `TimeZone.autoupdatingCurrent`. It applies the explicit locale and zone to the copied calendar, preventing that value from retaining ambient settings.

## Precision

The current approximate backend is `Double`. A precision request accepts 1 through 17 digits for representational round trips. Constants, roots, and Foundation transcendental functions record the requested precision capped at 15 digits; this is explicitly request metadata, not a claim that every result has 15 mathematically accurate digits. Derived approximate arithmetic uses unspecified precision rather than inventing an error bound.

`round(x)` uses the injected rounding rule. `floor` and `ceil` retain their mathematical direction regardless of that preference.

## Functions

The context-aware evaluator supports `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `ln`, `log`/`log10`, and `exp`. `log` is base 10; `ln` is natural logarithm. Invalid real domains and nonrepresentable approximate results are typed, ranged errors.

Date, calendar, and time-zone values are injected now so later date grammar cannot introduce ambient state. Their expression syntax and date arithmetic remain Phase 7 work.
