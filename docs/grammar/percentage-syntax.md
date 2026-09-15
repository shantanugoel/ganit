# Percentage syntax and semantics

Ganit represents a percentage as a typed value whose `points` retain the same
exact numeric representation used by ordinary arithmetic. For example, `20%`
is a percentage with 20 points; it is not immediately flattened to `0.2`.
Formatting uses the locale's percent-symbol placement while canonical output
always uses `%`.

Supported forms:

- `20% of 50` evaluates to `10`.
- `50 + 8%` and `8% on 50` evaluate to `54`.
- `50 - 20%` and `20% off 50` evaluate to `40`.
- `50 is what % of 200` evaluates to `25%`.
- `percentage change from 80 to 100` evaluates to `25%`.
- `80 after 20% off` and `120 after 20% on` evaluate to `100`.

Percentage signs participate algebraically. A negative percentage reverses the
direction implied by `off` or `on`: `-20% off 50` is `60`, while `-20% on 50`
is `40`. Write `-(20% off 50)` when negating the completed result.

The postfix `%` operator applies to the immediately preceding operand and
binds more tightly than powers and arithmetic. Thus `2^3%` means `2^(3%)`;
write `(2^3)%` when the completed power is the percentage value.
`of`, `off`, and `on` bind like multiplication, while ratio, change, and
reverse-percent phrases bind below addition. Parentheses remain available when
the intended grouping differs.

Percentage addition and subtraction preserve the percentage type.
Multiplying a number by a percentage applies its rate. Dividing a percentage
by a number preserves the percentage type. Unsupported mixed-type operations
fail with `evaluation.typeMismatch`; they are never silently flattened.
Division-by-zero and resource-limit behavior is inherited from exact numeric
operations.

`%` is exclusively the percentage marker and never means modulo. A future
word-form `mod` operator may provide modulo without overloading `%`.

This phase intentionally changes `Evaluator.evaluate` and
`CalculationResult.value` to return `EngineValue`, whose cases distinguish
numbers from percentages. Callers switch over that value before using its
typed payload. `ResultFormatter` accepts the same top-level value.
