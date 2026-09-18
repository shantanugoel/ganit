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

## How a sheet asks for its answers

`DisplayOptions` carries what a sheet says about writing answers, and travels
with the sheet in `SheetPreferences.display`. It says two things:

- `groupsDigits` groups digits the way the locale groups them, `1,234,567`, or
  leaves them alone, `1234567`.
- `numbers` is one of `automatic`, the decimals the value needs, and a power
  of ten at or above `1e21` or below `1e-6`, rounded to the context's digits;
  `fixedDecimals(n)`, always `n` of them, clamped to
  `NumberDisplay.decimalLimit`; `scientific`, a power of ten such as
  `1.2e6`; `hexadecimal` or `binary`, `0xff` and `0b1010`, all three of which
  the grammar reads back; or `fraction`, `3/4`. Hexadecimal and binary write
  whole numbers only, and fractions write fractions only; anything else keeps
  the automatic form.

A fixed count rounds the value itself, so `2/3` at two decimals is `0.67`
rounded from the fraction rather than from a decimal already rounded to the
context's significant digits. `fullPrecision` is unchanged by any of this: how
an answer reads is not what it is, and copying still yields `2/3`.

Money is written the way its currency is written, so a sheet's decimals and
powers of ten leave it alone; its digits still group with the rest. The Format
menu offers automatic, whole numbers, two and four decimals, scientific, Group
Digits, and Group Digits in Lakhs, and a change rewrites the answers already on screen without
evaluating anything again.

Formatting is bounded by `FormattingLimits`. The formatter preflights
arbitrary-scale zero padding and grouping growth before allocation and throws
`FormattingError.outputTooLong` when either output would exceed the configured
character limit.

## Where the words come from

Diagnostic messages, rate provenance, and rate periods are written in a string
catalog that ships as this module's resource bundle. `FormattingResources`
finds it, rather than SwiftPM's generated `Bundle.module`, which looks only
beside the executable and in the absolute build directory of the machine that
compiled it and stops the program when it finds neither. A sandboxed app
reaches neither of those, so `Bundle.module` crashed the shipped app the first
time a line failed; `ModuleBoundaryTests` now keeps it out of `Sources`.

The search covers the layouts Ganit is assembled into: an app's
`Contents/Resources`, a package build's product directory, the resources a
helper such as the command-line tool sits beside, and the directory a test
bundle is built into. A bundle that cannot be found leaves each message as the
English written at its call site, because wording an answer is not worth
stopping for.

`DiagnosticFormatter` turns syntax, evaluation, and formatting failures into
`FormattedDiagnostic` values. The engine retains stable codes, severity,
source ranges, fix-its, and localization-neutral typed context; the formatting
layer resolves the code through its string catalog using the injected locale.
The internal harness emits every syntax diagnostic and includes a concise
message and source range for each source-expression failure.
