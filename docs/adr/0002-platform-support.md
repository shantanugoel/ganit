# ADR 0002: Target macOS 14 and Apple silicon

- Status: Accepted
- Date: 2026-09-14

## Context

The product plan sets macOS 14 as the initial minimum. Ganit also has strict launch, typing, memory, and accessibility gates that must be verified on every supported platform. In 2026, the current macOS release supports only a small residual set of Intel Macs while every supported Mac category has Apple silicon models. Supporting x86_64 would double architecture validation and profiling for a new, unreleased product without current user evidence.

The local baseline is Xcode 26.5 with Swift 6.3.2 on arm64. Xcode 26 supports macOS deployment targets that include macOS 14.

## Decision

- Set `macOS 14.0` as the deployment target for all application and package products.
- Build and distribute arm64 only. Intel/x86_64 is not supported.
- Use Swift 6 language mode. Enable strict concurrency explicitly per module until all modules can use complete checking.
- Compile with the pinned CI Xcode version selected by the repository workflow; update that pin deliberately with a passing clean build and test run.
- Test runtime behavior on macOS 14 and the current macOS release. Use `#available` only for genuine newer-system features, with one straightforward system fallback.

This is a platform boundary, not a compatibility layer. Code does not carry alternate Intel implementations or recreate newer API behavior on macOS 14.

## Consequences

- The implementation and performance matrix remain small enough to test honestly.
- Users of Intel Macs cannot run Ganit.
- APIs newer than macOS 14 require availability guards and native fallbacks.
- Raising the minimum OS or adding an architecture requires a new ADR with measured demand, CI capacity, and performance evidence.

## References

- [Xcode system requirements](https://developer.apple.com/xcode/system-requirements/)
- [Macs compatible with macOS Tahoe 26](https://support.apple.com/en-us/122867)
