#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
sample_count=${1:-1}
application=${2:-"$repository_root/.build/app/release/Ganit.app"}
# Any app bundle can be measured this way, so the executable comes from the
# bundle rather than being assumed to be Ganit's.
executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
  "$application/Contents/Info.plist")
executable="$application/Contents/MacOS/$executable_name"
probe_directory=$(mktemp -d "${TMPDIR%/}/ganit-launch-probe.XXXXXX")
probe="$probe_directory/LaunchProbe"

trap 'rm -rf "$probe_directory"' EXIT

xcrun swiftc \
  -swift-version 6 \
  -O \
  "$repository_root/Tests/Support/LaunchProbe.swift" \
  -o "$probe"

# Cold launch until the app's first ordinary window (layer 0) is visible.
"$probe" "$executable" "$sample_count"

# Resident memory of the app idling with that window open.
"$executable" >/dev/null 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; rm -rf "$probe_directory"' EXIT
sleep 5
footprint_output=$(footprint -p "$pid" 2>/dev/null || true)
phys_footprint=$(awk '/phys_footprint:/ { print $2, $3; exit }' <<<"$footprint_output")
echo "idle_phys_footprint=${phys_footprint:-unavailable}"
echo "idle_rss_kib=$(ps -o rss= -p "$pid" | tr -d ' ')"
