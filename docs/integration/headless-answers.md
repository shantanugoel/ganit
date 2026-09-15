# Headless answers

Ganit answers one expression for callers outside its windows: the **Evaluate
Expression** macOS service and the **Calculate Expression** Shortcuts action. Both go
through `ExpressionCalculation`, so neither parses nor evaluates on its own and
both answer exactly as a sheet displays it.

## The shared calculation

`ExpressionCalculation.answer(for:)` builds an evaluation context from
`SheetPreferences`, evaluates with `CalculationEngine`, and formats with
`ResultFormatter`.

- Source arrives from another process, so it is bounded at 4 KB of UTF-8,
  far below the editor's limits.
- An expression that cannot be answered throws `UnevaluableExpression`, which
  carries the engine's formatted diagnostics. A caller explains the problem
  instead of returning a guess or nothing.
- Nothing is read or written outside the request, so no sheet, history, or
  clipboard is touched.

Currency needs exchange rates. `ExpressionCalculation.usingStoredRates()` reads
the snapshot the app last accepted from `RateSnapshotStore`, so a headless
answer never reaches the network. Without a stored snapshot, currency
conversion fails with the engine's unavailable-rates diagnostic rather
than inventing a rate.

## Evaluate Expression

The bundle's `NSServices` entry registers the service for
`public.utf8-plain-text`, both sent and returned, and
`ExpressionServiceProvider` implements it. The provider reads only the
pasteboard the system hands it and replaces the expression with its answer. A
failure returns a message for the system to show and leaves the selected text
unchanged.

The app installs the provider at launch and gives it the exchange rates it
currently holds, so a service request answers currency the same way an open
sheet does.

## Calculate Expression

`CalculateExpressionIntent` takes one `expression` parameter and returns the
answer as a string. `openAppWhenRun` is false, so a shortcut gets an answer
without a window appearing.

Shortcuts discovers an intent through App Intents metadata in the bundle. Xcode generates that metadata; SwiftPM does not, so
`Scripts/build-app.sh` runs the same two steps: `swift-frontend` extracts
constant values for the `GanitSystemIntegration` sources using the toolchain's
App Intents protocol list, then `appintentsmetadataprocessor` writes
`Contents/Resources/Metadata.appintents`. `Scripts/verify-app.sh` fails the
build if the intent is missing, undiscoverable, or opens the app.
