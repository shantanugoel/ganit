# Releasing Ganit

Ganit ships as a notarized direct download first ([ADR 0007](../adr/0007-distribution.md)).
The Mac App Store is evaluated after the direct release.

## Prerequisites

- A **Developer ID Application** signing identity in the login keychain.
- A notarytool keychain profile, created once:

```bash
xcrun notarytool store-credentials ganit-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

- Sparkle's EdDSA update key in the login keychain, made once with
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. Its public half is
  `SUPublicEDKey` in `App/Info.plist`; every installed copy of Ganit refuses
  an update signed by anything else, so losing the private half means no
  installed copy can ever be updated again, short of Sparkle's key rotation.
  Export it to another Mac with `generate_keys -x`, and keep that file
  somewhere safer than a downloads folder.

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

The disk image is about 2.6 MB, against the 15 MB download target.

## Run the signed app before releasing it

Open the built app, type a line that fails, such as `1 +`, and read the message
beside it. Some faults exist only in the shipped layout: a sandboxed app reaches
neither the build directory nor anything beside its executable, so a resource
the package build finds can be missing there, and the app stops instead of
saying anything. That is how `73bea03` was found, after every automated check
had passed. Also open a sheet with money in it and show where a rate came from,
which reads from the same string catalog.

## Publish by pushing a tag

`.github/workflows/release.yml` runs on a `v*` tag. It refuses a tag that does
not match `CFBundleShortVersionString` in `App/Info.plist`, or an
`App/Info.plist` whose two version numbers disagree, runs the tests, puts the
Developer ID identity in a keychain that exists only for that run, runs
`scripts/release.sh`, writes an `appcast.xml` describing the new version, and
publishes both it and the notarized disk image as the release for that tag
with generated notes.

The appcast is what installed copies of Ganit read, from
`releases/latest/download/appcast.xml`: a fixed URL that GitHub resolves to
the newest release's copy of the file ([ADR 0013](../adr/0013-sparkle-updates.md)).
So every release must carry one, which is why the workflow publishes them
together.

So a release is:

```bash
# App/Info.plist already says 0.2.0, and main is green
git tag v0.2.0 && git push origin v0.2.0
```

The workflow needs five repository secrets. Without them it fails rather than
publishing a build Gatekeeper would refuse:

| Secret | What it is |
|---|---|
| `GANIT_SIGNING_CERTIFICATE` | The Developer ID Application certificate and key, exported as `.p12` and base64-encoded |
| `GANIT_SIGNING_CERTIFICATE_PASSWORD` | The password set when exporting it |
| `GANIT_APPLE_ID` | The Apple ID that notarizes |
| `GANIT_TEAM_ID` | Its team identifier |
| `GANIT_NOTARY_PASSWORD` | An app-specific password for that Apple ID |
| `GANIT_SPARKLE_PRIVATE_KEY` | The EdDSA update key, exported with `generate_keys -x` |

```bash
base64 -i Ganit-DeveloperID.p12 | pbcopy   # the value for the first secret
```

## Updates

Ganit installs its own updates through Sparkle, and asks for none until the
reader asks ([ADR 0013](../adr/0013-sparkle-updates.md)). Before announcing a
release, install the previous version in `/Applications`, choose **Ganit ▸
Check for Updates…**, and watch it replace itself: a feed, a signature, or a
nested signing mistake shows up here and nowhere else.

## Status

Every step has now been run. On 16 September 2026 `scripts/release.sh` built
0.1.0 on the development Mac, signed it with `Developer ID Application:
Shantanu Goel (A8L3M4746U)`, and Apple's notary service accepted both
submissions, the app and then the disk image. Both were stapled and validated,
and Gatekeeper assessed both as `source=Notarized Developer ID`. The image is
2.8 MB, well inside the 15 MB download budget.

So the credential-gated part is no longer theoretical: Developer ID signing,
both notarizations, stapling, and the `spctl` assessments all behave as this
document describes.

The workflow has since done the same from a keychain that existed only for its
run. Pushing `v0.1.1` that afternoon tested, signed, notarized, and published a
disk image and an appcast in five and a half minutes, unattended. A 0.1.0 in
`/Applications` then found 0.1.1 through **Check for Updates…**, verified the
signature, and replaced itself, which is the whole path a reader takes and the
only way to know the nested signing and the sandboxed installer agree.
