# ADR 0007: Ship a notarized direct-download app first

- Status: Accepted
- Date: 2026-09-14

## Context

Ganit needs a distribution choice before signing, update, purchase, and sandbox assumptions spread through the application. Direct distribution permits one deliberate release path while preserving native Gatekeeper protections. Shipping through two channels at launch would double receipt, update, review, and release validation before demand justifies it.

## Decision

- Launch as a direct-download, arm64 macOS app.
- Sign releases with Developer ID Application, Hardened Runtime, and least-privilege App Sandbox entitlements.
- Submit with `notarytool`, staple the accepted ticket to the app and final disk image, then verify with `codesign`, `spctl`, and `stapler`.
- Use ad-hoc signatures only for local and CI builds; they are never release artifacts.
- Evaluate the Mac App Store after direct release using measured demand and sandbox, update, and purchase implications. Do not maintain channel-specific feature behavior meanwhile.

## Consequences

- Phase 0 needs no StoreKit, receipt validation, updater, release credential, or App Store project variant.
- Phase 12 must add signed update and release automation without putting credentials in the repository.
- Adding an App Store channel requires a new ADR and one shared product implementation.

## References

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
