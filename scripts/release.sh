#!/bin/bash

# Builds, signs, notarizes, and staples a direct-download release as ADR 0007
# describes. Credentials never enter the repository:
#
#   GANIT_SIGNING_IDENTITY  a "Developer ID Application: …" identity in the keychain
#   GANIT_NOTARY_PROFILE    a notarytool keychain profile, created once with
#                           `xcrun notarytool store-credentials`
#
# Output: .build/release/Ganit-<version>.dmg, notarized and stapled.
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repository_root"

: "${GANIT_SIGNING_IDENTITY:?Set GANIT_SIGNING_IDENTITY to a Developer ID Application identity.}"
: "${GANIT_NOTARY_PROFILE:?Set GANIT_NOTARY_PROFILE to a notarytool keychain profile.}"
if [[ "$GANIT_SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Releases are signed with a Developer ID Application identity." >&2
    exit 1
fi

application=$(./scripts/build-app.sh release | tail -1)
./scripts/verify-app.sh "$application"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$application/Contents/Info.plist")
output="$repository_root/.build/release"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$output"

sign() {
    codesign --force --timestamp --options runtime --sign "$GANIT_SIGNING_IDENTITY" "$@"
}

./scripts/sign-app.sh "$application" "$GANIT_SIGNING_IDENTITY"
codesign --verify --deep --strict "$application"

# Notarize and staple the app, so it launches offline wherever it is copied.
ditto -c -k --keepParent "$application" "$work/Ganit.zip"
xcrun notarytool submit "$work/Ganit.zip" --keychain-profile "$GANIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$application"

# Package, sign, notarize, and staple the disk image.
disk_image="$output/Ganit-$version.dmg"
rm -f "$disk_image"
mkdir "$work/image"
ditto "$application" "$work/image/Ganit.app"
ln -s /Applications "$work/image/Applications"
hdiutil create -volname "Ganit $version" -srcfolder "$work/image" -format UDZO "$disk_image"
sign "$disk_image"
xcrun notarytool submit "$disk_image" --keychain-profile "$GANIT_NOTARY_PROFILE" --wait
xcrun stapler staple "$disk_image"

xcrun stapler validate "$application"
xcrun stapler validate "$disk_image"
spctl --assess --type execute --verbose "$application"
spctl --assess --type open --context context:primary-signature --verbose "$disk_image"
echo "$disk_image"
