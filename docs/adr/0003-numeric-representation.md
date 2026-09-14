# ADR 0003: Build exact numbers on a pinned Swift BigInt

- Status: Accepted
- Date: 2026-09-14

## Context

Ganit must keep integers, rationals, typed decimals, money, and exact unit ratios out of binary floating-point paths. Swift has no standard arbitrary-precision integer, and implementing one locally would create a large correctness and security burden. Foundation `Decimal` is base-10 but bounded and cannot be the arbitrary-scale value model required by the correctness contract.

`attaswift/BigInt` is a pure-Swift arbitrary-precision implementation under the MIT license. It has been maintained since 2015, received releases in 2024, 2025, and 2026, and released Swift 6 package version 6.0.1 on 2026-08-19. Its suite includes unit and property tests but no dedicated fuzz target, so Ganit cannot treat upstream validation as sufficient.

The dependency was audited on 2026-09-14 at tag 6.0.1, revision `63feef7820abb1a8fb08587d7da56bb0b7db8751`, using Xcode 26.5 and Swift 6.3.2 on arm64:

- All 211 upstream release tests passed. Four existing compile warnings concern intentional overflowing `Float` test literals.
- A release executable that multiplies and then divides the integers 1 through 2,000 completed in 0.50 seconds wall time and 0.01 seconds user CPU, including process launch.
- With whole-module optimization and dead stripping, a minimal linked executable was 316,800 bytes versus a 50,648-byte Swift baseline: a 266,152-byte incremental footprint.
- The checked-out source directory was 160 KiB.

This smoke benchmark establishes that the dependency is small enough for the initial 15 MB compressed-download target; it does not substitute for Phase 1 expression benchmarks or application bundle measurements.

## Decision

- Pin `attaswift/BigInt` to tag `6.0.1` and verify the resolved revision above.
- Isolate `BigInt` and `BigUInt` behind Ganit-owned integer operations in `GanitEngine`; other modules do not import the dependency directly.
- Represent a rational as a normalized signed numerator and positive denominator using arbitrary-precision integers.
- Represent a finite decimal as an arbitrary-precision coefficient and base-10 scale. Preserve typed decimal scale where it carries user intent; normalize only where the operation's semantics allow it.
- Represent approximate results separately, including precision and approximation metadata. Transcendental implementations may use bounded floating-point internally only after crossing an explicit approximate operation.
- Specify rounding through an injected precision context. Display rounding never mutates the stored value.
- Keep money as a decimal amount plus ISO currency; do not route it through `Double`.

Preserve its MIT notice. Phase 1 must add Ganit-owned arithmetic properties, differential checks, numeric-boundary fuzzing, malformed-input fuzzing, and representative expression benchmarks before the numeric engine exit gate passes.

## Consequences

- Exact arithmetic shares one arbitrary-precision foundation without implementing BigInt.
- Dependency updates are deliberate correctness changes, not open version ranges.
- Decimal division, roots, powers, and transcendental functions need explicit termination and precision rules.
- Ganit remains responsible for end-to-end property, differential, fuzz, performance, and denial-of-service tests.

## References

- [`attaswift/BigInt` 6.0.1](https://github.com/attaswift/BigInt/releases/tag/v6.0.1)
- [`attaswift/BigInt` license](https://github.com/attaswift/BigInt/blob/v6.0.1/LICENSE.md)
