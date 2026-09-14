#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
application=${1:-"$repository_root/.build/app/release/Ganit.app"}

cd "$repository_root"

codesign --verify --deep --strict "$application"
signature_details=$(codesign -dvv "$application" 2>&1)
[[ "$signature_details" == *"flags="*"runtime"* ]]
test "$(lipo -archs "$application/Contents/MacOS/Ganit")" = "arm64"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$application/Contents/Info.plist")" = "APPL"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$application/Contents/Info.plist")" = "14.0"

privacy_manifest="$application/Contents/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$privacy_manifest" >/dev/null
cmp -s App/PrivacyInfo.xcprivacy "$privacy_manifest"
cmp -s \
  .build/checkouts/BigInt/LICENSE.md \
  ThirdPartyNotices/BigInt-LICENSE.md
cmp -s \
  ThirdPartyNotices/BigInt-LICENSE.md \
  "$application/Contents/Resources/BigInt-LICENSE.md"
privacy_declaration=$(plutil -convert json -o - "$privacy_manifest")
test "$privacy_declaration" = '{"NSPrivacyCollectedDataTypes":[],"NSPrivacyTracking":false}'

source_entitlements=$(plutil -convert json -o - App/Ganit.entitlements)
test "$source_entitlements" = '{"com.apple.security.app-sandbox":true}'
signed_entitlements=$(
  codesign -d --entitlements - --xml "$application" 2>/dev/null |
    plutil -convert json -o - -
)
test "$signed_entitlements" = "$source_entitlements"
test ! -e "$application/Contents/Frameworks"
