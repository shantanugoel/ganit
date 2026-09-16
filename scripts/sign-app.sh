#!/bin/bash

# Signs a built Ganit.app inside out: Sparkle's updater tools, then Sparkle
# itself, then the command, then the app with its entitlements. Code inside a
# bundle must be signed before the bundle that seals it.
#
#   scripts/sign-app.sh <path to Ganit.app> <identity>
#
# The identity is `-` for a local ad-hoc signature, or a
# "Developer ID Application: …" identity for a release.
set -euo pipefail

application=${1:?usage: $0 <Ganit.app> <identity>}
identity=${2:?usage: $0 <Ganit.app> <identity>}
repository_root=$(cd "$(dirname "$0")/.." && pwd)

# An ad-hoc signature cannot be timestamped, and library validation, part of
# the hardened runtime, refuses to load an ad-hoc framework into an ad-hoc app
# because neither has a team. A local build therefore asks for an exception
# that a release, signed with one Developer ID throughout, never gets.
options=(--force --sign "$identity" --options runtime)
entitlements="$repository_root/App/Ganit.entitlements"
if [[ "$identity" == "-" ]]; then
    options+=(--timestamp=none)
    development=$(mktemp -t Ganit.entitlements)
    trap 'rm -f "$development"' EXIT
    cp "$entitlements" "$development"
    /usr/libexec/PlistBuddy \
        -c 'Add :com.apple.security.cs.disable-library-validation bool true' \
        "$development" >/dev/null
    entitlements="$development"
else
    options+=(--timestamp)
fi

sign() {
    codesign "${options[@]}" "$@"
}

sparkle="$application/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign "$sparkle/Updater.app"
sign "$sparkle/Autoupdate"
sign "$sparkle"
sign "$application/Contents/Helpers/ganit"
sign --entitlements "$entitlements" "$application"
