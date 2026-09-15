# Result formatting

`GanitFormatting` turns evaluated values into presentation strings. It
does not parse source, perform calculations, or change the value.

`ResultFormatter` formats the complete `EngineValue` model, including typed
percentages. It delegates numeric representation to `NumericResultFormatter`
and applies the locale's percent-symbol placement without converting exact
percentage points through binary floating point. Both return a
`FormattedResult` with:

- `display`: localized digits, signs, separators, grouping, and rounding for
  presentation.
- `fullPrecision`: a stable, locale-neutral representation suitable for copy
  and inspection.
- `isApproximate`: an explicit exact-versus-approximate signal.

Exact integers and decimals retain every digit. Decimal scale, including
trailing zeroes, is preserved. Display conventions come from the injected
locale, independently of the locale syntax accepted by the lexer.

A rational displays as the decimal closest to it, rounded to the context's
significant digits and rounding rule with no trailing zeroes, because
`31250/4191 mi` is not a readable answer. Its `fullPrecision` remains the
exact fraction and `isApproximate` stays false: the value did not change and
no operation approximated it, only the presentation rounded. `RationalValue`
owns that rounding so the formatter never performs arithmetic.

Approximate values are prefixed with `≈`. Their display is rounded to the
smaller of the evaluation context's requested precision and any known
significant-digit metadata carried by the value. An absolute error bound is
conservatively converted to a significant-digit ceiling at the estimate's
magnitude. Very small and very large estimates use localized scientific
notation so a finite nonzero estimate is not displayed as zero. The
full-precision form uses Swift's locale-neutral, round-trippable `Double`
representation and remains marked approximate.

Formatting is bounded by `FormattingLimits`. The formatter preflights
arbitrary-scale zero padding and grouping growth before allocation and throws
`FormattingError.outputTooLong` when either output would exceed the configured
character limit.

`DiagnosticFormatter` turns syntax, evaluation, and formatting failures into
`FormattedDiagnostic` values. The engine retains stable codes, severity,
source ranges, fix-its, and localization-neutral typed context; the formatting
layer resolves the code through its string catalog using the injected locale.
The internal harness emits every syntax diagnostic and includes a concise
message and source range for each source-expression failure.
