#!/bin/bash

# Opens the built app with double-length strings and right-to-left layout
# for manual truncation, mirroring, and bidirectional text review.
set -euo pipefail

repository_root=$(cd "$(dirname "$0")/.." && pwd)
application=${1:-"$repository_root/.build/app/release/Ganit.app"}

open -n "$application" --args \
  -NSDoubleLocalizedStrings YES \
  -AppleTextDirection YES \
  -NSForceRightToLeftWritingDirection YES
