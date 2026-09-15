# ADR 0011: Point to releases before in-app installation

- Status: Accepted
- Date: 2026-09-15

## Context

A direct-download app needs a way for users to reach new versions. The common
choice for installing updates in place is Sparkle, which adds a third-party
dependency, a signed appcast on a host, an EdDSA signing key to protect, and a
second automatic network host beside the ECB rates that ADR 0006 allows. No
notarized release exists yet (ADR 0007), so there is nothing to install.

## Decision

- **Ganit ▸ Check for Updates…** opens the latest GitHub release,
  `https://github.com/shantanugoel/ganit/releases/latest`, in the browser.
- Ganit makes no update request itself and checks nothing in the background.
- Releases are the notarized disk images `scripts/release.sh` produces.

## Consequences

- No dependency, key, or network host is added, and the privacy statement stays
  true.
- Users compare versions and install by hand.
- Automatic in-app installation needs a new ADR once notarized releases ship,
  reviewing Sparkle or an alternative for signing, privacy, and sandbox fit.
