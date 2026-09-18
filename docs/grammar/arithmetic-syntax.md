# Arithmetic syntax

This reference describes the Phase 1 arithmetic parser, context-injected
evaluator, and separately layered result/diagnostic formatting.

## Expressions

- Binary operators: `+`, `-`, `*`/`×`, `/`/`÷`, `^`/`**`, and the whole-number
  bit operators `&`, `|`, `<<`, and `>>`
- Unary signs: `+` and `-`/`−`, and `√` before a value (`√2` is `sqrt(2)`)
- A postfix `!` is the factorial: `5!` is `120`
- Parentheses for explicit grouping
- Function-call syntax such as `sqrt(9)` and `max(1, 2)`
- Unicode UAX #31 identifiers such as `π`; `_` is also accepted

Bit operators bind below addition, in C's order: `|` loosest, then `&`, then the shifts. `xor(x, y)` is the exclusive or. They take whole numbers only. Multiplication and division bind more tightly than addition and subtraction. Powers are right-associative and bind more tightly than unary signs, so `-2^2` parses as `-(2^2)`.

Implicit multiplication is accepted only across an adjacent, unambiguous boundary such as `2π`, `2(3 + 4)`, or `(1 + 1)3`. Whitespace does not imply multiplication, and adjacent numeric literals such as `2 3` remain invalid.

Identifier starts and continuations use Unicode XID properties. Swift's canonical-equivalent string comparison makes composed and decomposed spellings equivalent; a standalone combining mark cannot start a name.

## Numeric literals

- Decimal integers: `1200`
- Locale decimals and grouping: `1,234.50` in `en-US`, `1.234,50` in `de-DE`.
  Where digits group in threes, lakh grouping reads too: `1,00,000` and
  `₹50,00,000`
- Scientific notation: `3.50e-2`
- Programmer integers: `0b1010`, `0o755`, and `0xff`
- Localized decimal digits, provided one literal does not mix digit scripts

The lexer receives decimal/grouping separators and grouping sizes explicitly. It preserves exact half-open UTF-8 and grapheme source ranges while normalizing digit values for the typed numeric layer. Source text itself is never rewritten.

In comma-decimal locales, use a semicolon between function arguments (`max(1; 2)`) so `1,2` remains an unambiguous decimal literal. A comma is an argument separator only when followed by whitespace. `1,` is an incomplete decimal, and `max(1 ,2)` is invalid rather than silently changing meaning.

## Evaluation

- `π`, `pi`, and `e` are explicitly approximate constants. `c` is the speed of
  light, `299,792,458 m/s`, exact by definition; a variable named `c` declared
  above takes precedence.
- `abs(x)`, `floor(x)`, `ceil(x)`, and `trunc(x)` take one argument. `round(x)`
  rounds to a whole number; `round(x, n)` keeps `n` digits after the decimal.
  Both `round` forms use the injected rounding rule. `n` is a non-negative whole
  number.
- `sign(x)` is −1, 0, or 1. `fact(n)` is factorial for a whole `n ≥ 0`.
  `cbrt(x)` is `root(x, 3)`. `mod(a, b)` is the remainder toward zero.
  `hypot(x, y)` is `sqrt(x² + y²)`. `clamp(x, low, high)` limits `x` to that
  range. `atan2(y, x)` is the two-argument arctangent in the injected angle
  mode. `log2(x)` is the base-2 logarithm.
- `ask_assistant(prompt)` and `prompt_assistant(prompt)` send the text inside
  the parentheses to a configured assistant and use the reply as a value.
- `min(x, y, ...)` and `max(x, y, ...)` require at least two arguments.
- `gcd(x, y)` and `lcm(x, y)` take whole numbers. `ncr(n, k)` and `npr(n, k)`
  count choices and arrangements.
- `stdev(x, y, ...)` is the sample standard deviation, over one less than the
  count; `stdevp` is the whole-population one. Both need two values and are
  approximate.
- `npv(rate, amount, ...)` discounts each amount by one more period than the
  one before, the first at period zero. The rate may be a percentage.
- `sqrt(x)` is equivalent to `root(x, 2)`. `root(x, degree)` requires a positive exact integer degree.
- `sin`, `cos`, and `tan` use the injected angle mode for a bare number; an angle with its unit, `sin(30°)` or `cos(1 rad)`, is read in that unit whatever the mode. `asin`, `acos`, and `atan` return angles in that mode.
- `ln(x)` is the natural logarithm; `log(x)` and `log10(x)` are base 10. `exp(x)` computes eˣ.
- `fv`, `pv`, and `pmt` are the [finance functions](finance-functions.md), the
  only functions that take and return money.
- Perfect powers and roots remain exact. Other roots become explicitly approximate.
- `0^0` is rejected as an invalid domain. A zero base with a negative exponent is division by zero.
- Even roots of negative values are invalid. Odd roots preserve the sign.
- Binary, octal, and hexadecimal literals evaluate to ordinary arbitrary-sized integers; their source radix does not change the value type.

Exact integer division produces an integer when evenly divisible and a reduced rational otherwise. Finite decimal results stay decimal where the operation remains naturally decimal. No exact value is silently coerced to floating point. Like a fraction, a decimal is displayed to the sheet's significant digits without trailing zeroes (`1.20 + 2.3` shows `3.5`, `1.05^10` shows `1.62889462677744`); Copy Full Precision keeps every digit.

Bitwise syntax is not part of this arithmetic grammar yet, while output-radix conversion belongs to result formatting.

## Syntax failures

Syntax failures carry a stable machine code and exact half-open UTF-8 and grapheme source range. A token inside parentheses that cannot continue the expression is reported as unexpected at that token, not as a missing `)`. The current codes cover unexpected characters, mixed digit scripts, missing or invalid radix digits, incomplete decimal fractions/exponents, exponent bounds, missing expressions or parentheses, missing argument separators, unexpected tokens, and resource limits.

One parse accepts at most 1 MiB of UTF-8 source, 100,000 tokens/lexical diagnostics, and an expression tree 128 levels deep. Every grouping, prefix, call argument, and operand nests one level, and so does each operator or phrase that extends a chain: `1 + 1 + ... + 1` may have at most 128 terms. Crossing a limit returns a ranged `resourceLimitExceeded` diagnostic instead of continuing into unbounded allocation or stack growth.

The depth limit bounds every recursive walk of the tree: parsing, evaluation, reference collection, comparison, and deallocation. Release builds use roughly 1.4 KiB of stack per parse level and 3 KiB per evaluation level on Apple silicon, so an expression at the limit fits the 512 KiB stack of a secondary thread; `StackSafetyTests` evaluates the deepest shape of each kind on such a thread.

Localized user-facing explanations, severity while typing, and fix-its are added with the typed-error task. A failed lex or parse returns no AST to evaluation.

## References

- [Unicode Standard Annex #31: Unicode Identifiers and Syntax](https://unicode.org/reports/tr31/)
