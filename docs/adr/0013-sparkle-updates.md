# ADR 0013: Install updates with Sparkle, after being asked

- Status: Accepted
- Date: 2026-09-16
- Supersedes: [ADR 0011](0011-update-path.md)

## Context

ADR 0011 pointed **Check for Updates…** at the releases page and had Ganit
make no request of its own, partly because no notarized release existed to
install. One now does: 0.1.0 was signed, notarized, stapled, and assessed by
Gatekeeper. Reaching a new version still means noticing a menu item, reading a
version number, downloading a disk image, and dragging it over the old app,
which is how people end up running last year's build.

The cost of doing better is a third network request, and Ganit's privacy
statement is short enough that a background request would read as a
contradiction of it.

## Decision

- Sparkle 2 is embedded, pinned exactly, with its installer service. Its
  downloader service is removed, because Ganit has the network client
  entitlement and does its own downloading.
- **Ganit asks nothing until it is asked.** `SUEnableAutomaticChecks` is false
  in `Info.plist`, so there is no first-launch prompt and no daily check.
  **Check for Updates…** asks once. **Check for Updates Automatically** asks
  once a day, and is off in a fresh copy.
- `SUEnableSystemProfiling` stays false: no version of macOS, no model, no
  language, nothing about the Mac travels with the request.
- An update is accepted only when signed by both Ganit's Developer ID
  certificate and Ganit's EdDSA update key.
- The feed is `releases/latest/download/appcast.xml`, an asset published with
  every release, so the URL is fixed while the file is not. It lists the
  latest release only; the releases page is the history.
- `CFBundleVersion` equals `CFBundleShortVersionString`, because Sparkle
  compares the former and a release whose two versions disagree offers itself
  to the people already running it.

## Consequences

- People get fixes, which is the point, and they get them only after saying so
  once.
- The privacy statement gains a third request and keeps its shape: nothing
  automatic that the reader did not turn on.
- The disk image grows from 2.8 MB to 3.7 MB, against a 15 MB budget.
- The update key must outlive the machine it was made on. Losing it means no
  installed copy can be updated again, recoverable only through Sparkle's key
  rotation, which needs a Developer ID signed release. It is kept in the login
  keychain and as the `GANIT_SPARKLE_PRIVATE_KEY` repository secret.
- Signing is now inside-out over nested code, which `scripts/sign-app.sh` does
  for both a local build and a release.
- Library validation refuses an ad-hoc framework inside an ad-hoc app, so a
  local build signs with `com.apple.security.cs.disable-library-validation`
  and a release never does. `verify-app.sh` checks that the exception appears
  only where there is no team.
- Updating works from `/Applications` and not from the mounted disk image,
  which is what the image's `/Applications` link is for.
