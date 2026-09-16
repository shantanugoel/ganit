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
./scripts/verify-unit-attribution.sh
plutil -lint App/Info.plist >/dev/null
plutil -lint App/Ganit.entitlements >/dev/null
plutil -lint App/PrivacyInfo.xcprivacy >/dev/null
swift build --configuration "$configuration" --arch arm64 --product GanitApp
swift build --configuration "$configuration" --arch arm64 --product ganit

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

mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources" "$staging/Contents/Helpers"
install -m 0755 "$binary_directory/GanitApp" "$staging/Contents/MacOS/Ganit"
install -m 0755 "$binary_directory/ganit" "$staging/Contents/Helpers/ganit"

# Sparkle installs updates in place, and the tools that do it live inside its
# framework, so the framework is copied whole, with its symlinks, and its
# nested code is signed before anything containing it.
sparkle_framework=$(find "$repository_root/.build/artifacts/sparkle" \
    -type d -path "*/Sparkle.xcframework/macos-*/Sparkle.framework" | head -1)
if [[ -z "$sparkle_framework" ]]; then
    echo "Sparkle.framework was not found; run swift build first." >&2
    exit 1
fi
mkdir -p "$staging/Contents/Frameworks"
ditto "$sparkle_framework" "$staging/Contents/Frameworks/Sparkle.framework"
# Ganit asks for outgoing connections itself, so Sparkle's downloader service
# is never used, and an unused service is one more thing to sign and trust.
rm -rf "$staging/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"

ditto \
    "$binary_directory/Ganit_GanitFormatting.bundle" \
    "$staging/Contents/Resources/Ganit_GanitFormatting.bundle"
xcrun xcstringstool compile \
    Sources/GanitFormatting/Resources/Localizable.xcstrings \
    --output-directory \
    "$staging/Contents/Resources/Ganit_GanitFormatting.bundle"
rm "$staging/Contents/Resources/Ganit_GanitFormatting.bundle/Localizable.xcstrings"
install -m 0644 App/Info.plist "$staging/Contents/Info.plist"
install -m 0644 App/PrivacyInfo.xcprivacy "$staging/Contents/Resources/PrivacyInfo.xcprivacy"
install -m 0644 \
    ThirdPartyNotices/BigInt-LICENSE.md \
    "$staging/Contents/Resources/BigInt-LICENSE.md"
install -m 0644 \
    ThirdPartyNotices/Sparkle-LICENSE.md \
    "$staging/Contents/Resources/Sparkle-LICENSE.md"
install -m 0644 \
    ThirdPartyNotices/UnitSources.md \
    "$staging/Contents/Resources/UnitSources.md"
install -m 0644 \
    CHANGELOG.md \
    "$staging/Contents/Resources/CHANGELOG.md"
xcrun xcstringstool compile \
    App/Resources/Localizable.xcstrings \
    --output-directory "$staging/Contents/Resources"

# Shortcuts and Spotlight find Calculate Expression through App Intents
# metadata, which the Swift compiler and Apple's processor produce from the
# intent's declaration. Xcode does this for its targets; SwiftPM does not.
toolchain_directory=$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")
intents_work="$build_root/AppIntents"
rm -rf "$intents_work"
mkdir -p "$intents_work"
plutil -extract constValueProtocols json -o "$intents_work/protocols.json" \
    "$toolchain_directory/usr/share/swift/SwiftConstantValues/AppIntents.json"
intent_sources=(Sources/GanitSystemIntegration/*.swift)
for source in "${intent_sources[@]}"; do
    constant_values="$intents_work/$(basename "$source" .swift).swiftconstvalues"
    others=()
    for other in "${intent_sources[@]}"; do
        [[ "$other" != "$source" ]] && others+=("$other")
    done
    xcrun swift-frontend -typecheck \
        -primary-file "$source" \
        "${others[@]}" \
        -module-name GanitSystemIntegration \
        -target arm64-apple-macos14.0 \
        -swift-version 6 \
        -sdk "$(xcrun --show-sdk-path)" \
        -I "$binary_directory/Modules" \
        -I "$binary_directory" \
        -const-gather-protocols-file "$intents_work/protocols.json" \
        -emit-const-values-path "$constant_values"
    echo "$constant_values" >>"$intents_work/constant-values.txt"
done
printf '%s\n' "${intent_sources[@]}" >"$intents_work/sources.txt"
xcrun appintentsmetadataprocessor \
    --output "$staging/Contents/Resources" \
    --toolchain-dir "$toolchain_directory" \
    --module-name GanitSystemIntegration \
    --sdk-root "$(xcrun --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | tail -1 | awk '{print $NF}')" \
    --platform-family macOS \
    --deployment-target 14.0 \
    --target-triple arm64-apple-macos14.0 \
    --source-file-list "$intents_work/sources.txt" \
    --swift-const-vals-list "$intents_work/constant-values.txt" \
    --force

architectures=$(lipo -archs "$staging/Contents/MacOS/Ganit")
if [[ "$architectures" != "arm64" ]]; then
    echo "Unexpected application architectures: $architectures" >&2
    exit 1
fi

./scripts/sign-app.sh "$staging" -
mv "$staging" "$application"
trap - EXIT

echo "$application"
