#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

generated=$(mktemp)
trap 'rm -f "$generated"' EXIT

swift run --quiet GanitUnitAttributionGenerator >"$generated"
cmp -s "$generated" ThirdPartyNotices/UnitSources.md
