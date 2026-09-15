#!/bin/bash
#
# Times one answer from a cold command-line process, for Ganit and for Numi's
# engine, and a whole sheet through Ganit's one process. Numi's terminal build
# answers a single expression per run, so it has no sheet figure.
#
#     swift build -c release && scripts/measure-cli.sh [runs]
#
# numi-cli is optional: brew install nikolaeu/numi/numi-cli

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
runs=${1:-30}

if [[ ! -x $root/.build/release/ganit ]]; then
  echo "Build the release command first: swift build -c release" >&2
  exit 1
fi

python3 - "$root" "$runs" <<'PYTHON'
import shutil, statistics, subprocess, sys, time

root, runs = sys.argv[1], int(sys.argv[2])
expressions = [
    "20% off 85", "2 + 3 * 4", "20 inches in cm", "12 km in miles",
    "1 kg in lbs", "10 USD + 5 USD", "2^64", "sqrt(16) + sin(pi / 2)",
]

def report(name, samples):
    samples.sort()
    index = min(len(samples) - 1, int(round(0.95 * len(samples))) - 1)
    print("%-9s n=%-4d median %6.1f ms  P95 %6.1f ms  min %6.1f ms" % (
        name, len(samples), statistics.median(samples), samples[index],
        samples[0]))

def time_each(command):
    samples = []
    for _ in range(runs):
        for expression in expressions:
            start = time.perf_counter()
            subprocess.run(command + [expression], capture_output=True)
            samples.append((time.perf_counter() - start) * 1000)
    return samples

report("ganit", time_each([root + "/.build/release/ganit"]))
if shutil.which("numi-cli"):
    report("numi-cli", time_each(["numi-cli"]))
else:
    print("numi-cli    not installed, skipped")

sheet = open(root + "/Benchmarks/Fixtures/mixed-sheet-1k.txt", "rb").read()
samples = []
for _ in range(max(1, runs // 3)):
    start = time.perf_counter()
    subprocess.run([root + "/.build/release/ganit"], input=sheet,
                   capture_output=True)
    samples.append((time.perf_counter() - start) * 1000)
report("ganit 1k", samples)
PYTHON
