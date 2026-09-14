# Arithmetic syntax

This reference describes the Phase 1 parser. Evaluation and result formatting are added by later Phase 1 tasks.

## Expressions

- Binary operators: `+`, `-`, `*`/`×`, `/`/`÷`, and `^`
- Unary signs: `+` and `-`/`−`
- Parentheses for explicit grouping
- Function-call syntax such as `sqrt(9)` and `max(1, 2)`
- Unicode UAX #31 identifiers such as `π`; `_` is also accepted

Multiplication and division bind more tightly than addition and subtraction. Powers are right-associative and bind more tightly than unary signs, so `-2^2` parses as `-(2^2)`.

Implicit multiplication is not accepted yet. Write `2 * π` rather than `2π`.

Identifier starts and continuations use Unicode XID properties. Swift's canonical-equivalent string comparison makes composed and decomposed spellings equivalent; a standalone combining mark cannot start a name.

## Numeric literals

- Decimal integers: `1200`
- Locale decimals and grouping: `1,234.50` in `en-US`, `1.234,50` in `de-DE`
- Scientific notation: `3.50e-2`
- Programmer integers: `0b1010`, `0o755`, and `0xff`
- Localized decimal digits, provided one literal does not mix digit scripts

The lexer receives decimal/grouping separators and grouping sizes explicitly. It preserves exact half-open UTF-8 and grapheme source ranges while normalizing digit values for the typed numeric layer. Source text itself is never rewritten.

In comma-decimal locales, use a semicolon between function arguments (`max(1; 2)`) so `1,2` remains an unambiguous decimal literal. A comma is an argument separator only when followed by whitespace. `1,` is an incomplete decimal, and `max(1 ,2)` is invalid rather than silently changing meaning.

## Syntax failures

Syntax failures carry a stable machine code and exact half-open UTF-8 and grapheme source range. The current codes cover unexpected characters, mixed digit scripts, missing or invalid radix digits, incomplete decimal fractions/exponents, exponent bounds, missing expressions or parentheses, missing argument separators, unexpected tokens, and resource limits.

One parse accepts at most 1 MiB of UTF-8 source, 100,000 tokens/lexical diagnostics, and 256 recursive Pratt-parser levels. Crossing a limit returns a ranged `resourceLimitExceeded` diagnostic instead of continuing into unbounded allocation or stack growth.

Localized user-facing explanations, severity while typing, and fix-its are added with the typed-error task. A failed lex or parse returns no AST to evaluation.

## References

- [Unicode Standard Annex #31: Unicode Identifiers and Syntax](https://unicode.org/reports/tr31/)
