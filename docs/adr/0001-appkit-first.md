# ADR 0001: Use AppKit for the application UI

- Status: Accepted
- Date: 2026-09-14

## Context

Ganit is primarily a text editor, multiwindow document library, and low-latency floating panel. It depends on native selection, marked text and IME composition, bidirectional text, undo grouping, Find, Services, responder-chain commands, accessibility, window restoration, toolbars, sidebars, and precise layout instrumentation. Reimplementing those behaviors would add risk without differentiating the product.

## Decision

Build the application surfaces with AppKit:

- `NSApplication` and standard `NSWindow`/`NSPanel` subclasses own application and window behavior.
- `NSTextView` and TextKit own source editing. Answers and decorations must not alter the source string or its offsets.
- Standard AppKit split views, sidebars, toolbars, menus, popovers, settings, focus, and restoration APIs are the default.
- UI state is isolated to the main actor and consumes immutable engine snapshots.
- Newer macOS visual APIs are adopted through standard components behind availability checks. Ganit does not custom-paint platform materials.

SwiftUI is not part of the initial application skeleton. It may be introduced for an isolated surface only when it measurably improves that surface without harming launch time, memory, text behavior, accessibility, or command routing.

## Consequences

- The app follows native Mac conventions and gains mature accessibility and text-system behavior.
- UI tests must cover marked text, bidirectional text, responder-chain commands, VoiceOver, restoration, and multiple windows.
- Calculation remains outside UI modules; no AppKit type may enter `GanitEngine`.
- AppKit-specific coordination code is expected and is preferable to parallel AppKit and SwiftUI implementations.

## References

- [AppKit](https://developer.apple.com/documentation/appkit)
- [Restoring your app's state with AppKit](https://developer.apple.com/documentation/appkit/restoring-your-app-s-state-with-appkit)
- [Make your Mac app more accessible to everyone](https://developer.apple.com/videos/play/wwdc2025/229/)
