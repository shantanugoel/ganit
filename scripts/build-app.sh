#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
configuration=${1:-release}

case "$configuration" in
    debug|release) ;;
    *)
        echo "usage: $0 [debug|release]" >&2
        exit 64
        ;;
esac

if [[ $(uname -m) != "arm64" ]]; then
    echo "Ganit builds and distributes for Apple silicon only." >&2
    exit 1
fi

cd "$repository_root"
plutil -lint App/Info.plist >/dev/null
plutil -lint App/Ganit.entitlements >/dev/null
plutil -lint App/PrivacyInfo.xcprivacy >/dev/null
swift build --configuration "$configuration" --arch arm64 --product GanitApp

binary_directory=$(swift build \
    --configuration "$configuration" \
    --arch arm64 \
    --show-bin-path)
build_root="$repository_root/.build/app/$configuration"
application="$build_root/Ganit.app"
staging="$build_root/Ganit.staging.app"

mkdir -p "$build_root"
rm -rf "$application" "$staging"
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
install -m 0755 "$binary_directory/GanitApp" "$staging/Contents/MacOS/Ganit"
install -m 0644 App/Info.plist "$staging/Contents/Info.plist"
install -m 0644 App/PrivacyInfo.xcprivacy "$staging/Contents/Resources/PrivacyInfo.xcprivacy"
xcrun xcstringstool compile \
    App/Resources/Localizable.xcstrings \
    --output-directory "$staging/Contents/Resources"

architectures=$(lipo -archs "$staging/Contents/MacOS/Ganit")
if [[ "$architectures" != "arm64" ]]; then
    echo "Unexpected application architectures: $architectures" >&2
    exit 1
fi

codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --entitlements App/Ganit.entitlements \
    "$staging"
mv "$staging" "$application"
trap - EXIT

echo "$application"
