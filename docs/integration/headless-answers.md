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

## Calculate URL

Other apps and scripts can ask for an answer with an
[x-callback-url](https://x-callback-url.com):

```text
ganit://x-callback-url/calculate?expression=20%25%20off%2085&x-success=app://done&x-error=app://failed
```

`CalculationCallback` parses the request and `ExpressionCalculation` answers it,
with the exchange rates the app holds. Ganit opens `x-success` with a `result`
query item added, `app://done?result=68`, or `x-error` with `errorMessage`.
Without the matching callback nothing is opened.

This is the only URL action, and it is bounded:

- the URL is at most 8 KB and the expression keeps the 4 KB headless limit;
- the host must be `x-callback-url` and the path `/calculate`; any other
  action is ignored;
- parameters are limited to `expression`, `x-success`, `x-error`, `x-cancel`,
  and `x-source`, each at most once, so a request cannot smuggle extra input;
- a callback is an absolute URL of at most 2 KB that is not `ganit:`, which
  could loop, or `file:`, which would open local files.

The action reads and writes no sheet, buffer, or clipboard, and returns only the
answer to the caller's own expression, so it needs no confirmation. The bundle
declares the `ganit` scheme in `CFBundleURLTypes`, and `Scripts/verify-app.sh`
checks it.
