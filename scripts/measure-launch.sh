#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
sample_count=${1:-1}
application=${2:-"$repository_root/.build/app/release/Ganit.app"}
probe_directory=$(mktemp -d "${TMPDIR%/}/ganit-launch-probe.XXXXXX")
probe="$probe_directory/LaunchProbe"

trap 'rm -rf "$probe_directory"' EXIT

xcrun swiftc \
  -swift-version 6 \
  -O \
  "$repository_root/Tests/Support/LaunchProbe.swift" \
  -o "$probe"

"$probe" "$application/Contents/MacOS/Ganit" "$sample_count"
