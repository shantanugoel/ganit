# Arithmetic syntax

This reference describes the Phase 1 arithmetic parser, context-injected
evaluator, and separately layered result/diagnostic formatting.

## Expressions

- Binary operators: `+`, `-`, `*`/`×`, `/`/`÷`, and `^`
- Unary signs: `+` and `-`/`−`
- Parentheses for explicit grouping
- Function-call syntax such as `sqrt(9)` and `max(1, 2)`
- Unicode UAX #31 identifiers such as `π`; `_` is also accepted

Multiplication and division bind more tightly than addition and subtraction. Powers are right-associative and bind more tightly than unary signs, so `-2^2` parses as `-(2^2)`.

Implicit multiplication is accepted only across an adjacent, unambiguous boundary such as `2π`, `2(3 + 4)`, or `(1 + 1)3`. Whitespace does not imply multiplication, and adjacent numeric literals such as `2 3` remain invalid.

Identifier starts and continuations use Unicode XID properties. Swift's canonical-equivalent string comparison makes composed and decomposed spellings equivalent; a standalone combining mark cannot start a name.

## Numeric literals

- Decimal integers: `1200`
- Locale decimals and grouping: `1,234.50` in `en-US`, `1.234,50` in `de-DE`
- Scientific notation: `3.50e-2`
- Programmer integers: `0b1010`, `0o755`, and `0xff`
- Localized decimal digits, provided one literal does not mix digit scripts

The lexer receives decimal/grouping separators and grouping sizes explicitly. It preserves exact half-open UTF-8 and grapheme source ranges while normalizing digit values for the typed numeric layer. Source text itself is never rewritten.

In comma-decimal locales, use a semicolon between function arguments (`max(1; 2)`) so `1,2` remains an unambiguous decimal literal. A comma is an argument separator only when followed by whitespace. `1,` is an incomplete decimal, and `max(1 ,2)` is invalid rather than silently changing meaning.

## Evaluation

- `π`, `pi`, and `e` are explicitly approximate constants.
- `abs(x)`, `floor(x)`, `ceil(x)`, and `round(x)` take one argument. `round` uses the injected rounding rule.
- `min(x, y, ...)` and `max(x, y, ...)` require at least two arguments.
- `sqrt(x)` is equivalent to `root(x, 2)`. `root(x, degree)` requires a positive exact integer degree.
- `sin`, `cos`, and `tan` use the injected angle mode. `asin`, `acos`, and `atan` return angles in that mode.
- `ln(x)` is the natural logarithm; `log(x)` and `log10(x)` are base 10. `exp(x)` computes eˣ.
- Perfect powers and roots remain exact. Other roots become explicitly approximate.
- `0^0` is rejected as an invalid domain. A zero base with a negative exponent is division by zero.
- Even roots of negative values are invalid. Odd roots preserve the sign.
- Binary, octal, and hexadecimal literals evaluate to ordinary arbitrary-sized integers; their source radix does not change the value type.

Exact integer division produces an integer when evenly divisible and a reduced rational otherwise. Finite decimal results stay decimal where the operation remains naturally decimal. No exact value is silently coerced to floating point.

Bitwise syntax is not part of this arithmetic grammar yet, while output-radix conversion belongs to result formatting. Decimal-place arguments for `round` are not accepted.

## Syntax failures

Syntax failures carry a stable machine code and exact half-open UTF-8 and grapheme source range. The current codes cover unexpected characters, mixed digit scripts, missing or invalid radix digits, incomplete decimal fractions/exponents, exponent bounds, missing expressions or parentheses, missing argument separators, unexpected tokens, and resource limits.

One parse accepts at most 1 MiB of UTF-8 source, 100,000 tokens/lexical diagnostics, and 256 recursive Pratt-parser levels. Crossing a limit returns a ranged `resourceLimitExceeded` diagnostic instead of continuing into unbounded allocation or stack growth.

Localized user-facing explanations, severity while typing, and fix-its are added with the typed-error task. A failed lex or parse returns no AST to evaluation.

## References

- [Unicode Standard Annex #31: Unicode Identifiers and Syntax](https://unicode.org/reports/tr31/)
