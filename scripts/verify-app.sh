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
formatting_resources="$application/Contents/Resources/Ganit_GanitFormatting.bundle"
test -f "$formatting_resources/Info.plist"
test -f "$formatting_resources/en.lproj/Localizable.strings"
test -f "$formatting_resources/tr.lproj/Localizable.strings"
test ! -e "$formatting_resources/Localizable.xcstrings"

# Evaluate Expression is offered to other apps, and both Shortcuts actions are
# discoverable in Shortcuts and Spotlight.
test "$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSMessage' "$application/Contents/Info.plist")" = "evaluateExpression"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$application/Contents/Info.plist")" = "ganit"
test "$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSSendTypes:0' "$application/Contents/Info.plist")" = "public.utf8-plain-text"
intents_metadata="$application/Contents/Resources/Metadata.appintents/extract.actionsdata"
ruby -rjson -e '
  actions = JSON.parse(File.read(ARGV[0]))["actions"]
  intent = actions.fetch("CalculateExpressionIntent")
  abort "intent is not discoverable" unless intent["isDiscoverable"]
  abort "intent opens the app" if intent["openAppWhenRun"]
  open_sheet = actions.fetch("OpenSheetIntent")
  abort "Open Sheet is not discoverable" unless open_sheet["isDiscoverable"]
  abort "Open Sheet does not open the app" unless open_sheet["openAppWhenRun"]
' "$intents_metadata"

privacy_manifest="$application/Contents/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$privacy_manifest" >/dev/null
cmp -s App/PrivacyInfo.xcprivacy "$privacy_manifest"
cmp -s \
  .build/checkouts/BigInt/LICENSE.md \
  ThirdPartyNotices/BigInt-LICENSE.md
cmp -s \
  ThirdPartyNotices/BigInt-LICENSE.md \
  "$application/Contents/Resources/BigInt-LICENSE.md"
cmp -s \
  ThirdPartyNotices/UnitSources.md \
  "$application/Contents/Resources/UnitSources.md"
cmp -s \
  ThirdPartyNotices/CurrencyDataSources.md \
  "$application/Contents/Resources/CurrencyDataSources.md"
privacy_declaration=$(plutil -convert json -o - "$privacy_manifest")
test "$privacy_declaration" = '{"NSPrivacyCollectedDataTypes":[],"NSPrivacyTracking":false}'

# Entitlements are compared as key-sorted JSON.
sorted_json() {
  ruby -rjson -e 'puts JSON.generate(JSON.parse(STDIN.read).sort.to_h)'
}
source_entitlements=$(plutil -convert json -o - App/Ganit.entitlements | sorted_json)
test "$source_entitlements" = '{"com.apple.security.app-sandbox":true,"com.apple.security.files.user-selected.read-write":true,"com.apple.security.network.client":true}'
signed_entitlements=$(
  codesign -d --entitlements - --xml "$application" 2>/dev/null |
    plutil -convert json -o - - | sorted_json
)
test "$signed_entitlements" = "$source_entitlements"
test ! -e "$application/Contents/Frameworks"
test "$(lipo -archs "$application/Contents/Helpers/ganit")" = "arm64"
helper_signature=$(codesign -dvv "$application/Contents/Helpers/ganit" 2>&1)
[[ "$helper_signature" == *"flags="*"runtime"* ]]
test "$("$application/Contents/Helpers/ganit" '6 * 7')" = "42"
