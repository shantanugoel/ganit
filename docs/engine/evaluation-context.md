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

`round(x)` and `round(x, n)` use the injected rounding rule. `floor` and `ceil` retain their mathematical direction regardless of that preference.

## Functions

The context-aware evaluator supports `sin`, `cos`, `tan`, `asin`, `acos`, `atan`,
`atan2`, `ln`, `log`/`log10`, `log2`, and `exp`. `log` is base 10; `ln` is
natural logarithm. Invalid real domains and nonrepresentable approximate
results are typed, ranged errors. `ask_assistant` reads answers already
received from the context and never talks to a model.

Date, calendar, and time-zone values are injected so date grammar cannot introduce ambient state; see [temporal values](temporal-values.md) and [date and time syntax](../grammar/date-syntax.md). `at(_:)` returns the same context at another moment, which callers use to evaluate a sheet at the current time.
