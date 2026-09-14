#!/bin/bash

set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:-lint}
expected_xcode=$(<"$repository_root/.xcode-version")
expected_swift_format="6.3.0"
actual_xcode=$(xcodebuild -version | awk 'NR == 1 { print $2 }')
actual_swift_format=$(swift format --version)

if [[ "$actual_xcode" != "$expected_xcode" ]]; then
  echo "Expected Xcode $expected_xcode, found $actual_xcode." >&2
  exit 1
fi

if [[ "$actual_swift_format" != "$expected_swift_format" ]]; then
  echo "Expected swift-format $expected_swift_format, found $actual_swift_format." >&2
  exit 1
fi

paths=(
  "$repository_root/Package.swift"
  "$repository_root/Sources"
  "$repository_root/Tests"
)

case "$mode" in
  format)
    swift format \
      --configuration "$repository_root/.swift-format" \
      --in-place \
      --parallel \
      --recursive \
      "${paths[@]}"
    "$0" lint
    ;;
  lint)
    swift format lint \
      --configuration "$repository_root/.swift-format" \
      --strict \
      --parallel \
      --recursive \
      "${paths[@]}"
    ;;
  *)
    echo "usage: $0 [format|lint]" >&2
    exit 64
    ;;
esac
