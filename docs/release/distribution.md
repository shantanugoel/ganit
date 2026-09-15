# Releasing Ganit

Ganit ships as a notarized direct download first ([ADR 0007](../adr/0007-distribution.md)).
The Mac App Store is evaluated after the direct release.

## Prerequisites

- A **Developer ID Application** signing identity in the login keychain.
- A notarytool keychain profile, created once:

```bash
xcrun notarytool store-credentials ganit-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

Credentials stay in the keychain; nothing about them is committed.

## Build a release

```bash
GANIT_SIGNING_IDENTITY="Developer ID Application: NAME (TEAM)" GANIT_NOTARY_PROFILE=ganit-notary ./scripts/release.sh
```

`scripts/release.sh`:

1. builds the app and runs `scripts/verify-app.sh`;
2. signs `Contents/Helpers/ganit`, then the app with its entitlements, both with
   Hardened Runtime and a secure timestamp;
3. notarizes a zip of the app and staples the ticket to the app;
4. builds `Ganit-<version>.dmg` with an Applications link, signs it, notarizes
   it, and staples it;
5. validates both staples and checks both with Gatekeeper (`spctl`).

The disk image is about 2.5 MB, against the 15 MB download target.

## Updates

**Ganit ▸ Check for Updates…** opens the latest release on GitHub
([ADR 0011](../adr/0011-update-path.md)). Publish each notarized disk image as
a GitHub release so that link finds it.

## Status

The script refuses to run without a Developer ID identity and a notary
profile. Only the Apple Development identities exist on the development Mac,
so no notarized build has been produced yet; the unsigned build, verification,
and disk-image steps have been checked locally.
