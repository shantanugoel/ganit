#!/bin/bash
#
# Answers every expression in the compatibility corpus with Ganit and with
# another calculator, and prints the two answers side by side as a Markdown
# table for docs/quality/compatibility.md.
#
# Numi answers through numi-cli, which is Numi's own engine in a terminal:
#
#     brew install nikolaeu/numi/numi-cli
#
# Soulver and Apple Math Notes have no scriptable engine, so their rows in
# that document come from published documentation instead.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$root/Tests/GanitEngineCorpusTests/Fixtures/phase-11-compatibility.json"
ganit="$root/.build/debug/ganit"

if [[ ! -x $ganit ]]; then
  echo "Build the command first: swift build" >&2
  exit 1
fi
if ! command -v numi-cli >/dev/null; then
  echo "numi-cli is not installed: brew install nikolaeu/numi/numi-cli" >&2
  exit 1
fi

echo "Ganit $(cd "$root" && git rev-parse --short HEAD), $(numi-cli --version 2>&1 | tail -1)"
echo
echo "| Expression | Numi | Ganit |"
echo "| --- | --- | --- |"

python3 -c 'import json,sys
for case in json.load(open(sys.argv[1]))["cases"]:
    print(case["expression"])' "$fixture" |
  while IFS= read -r expression; do
    # Both commands exit nonzero on an expression they refuse, which is an
    # answer this table wants rather than a failure of the run.
    numi="$(numi-cli "$expression" 2>&1 | head -1 || true)"
    answer="$($ganit "$expression" 2>&1 | head -1 || true)"
    printf '| `%s` | %s | %s |\n' "$expression" "${numi:-—}" "${answer:-—}"
  done
