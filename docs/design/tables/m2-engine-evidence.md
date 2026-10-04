# M2 engine acceptance evidence

Date: 2026-10-03. Branch: `tables`.

M2 implements the table calculator foundation; mixed-sheet evaluation and
structural edits remain M3 work. The selected presentation is inline preview
plus Open Table. This record does not claim native editor acceptance.

## Incremental calculation and resource contract

`TableCalculator.calculate(previous:)` accepts an immutable previous snapshot
from the same calculator or a copy of it. A different calculator does a fresh
calculation, because its engine catalog and limits may differ. Changed plans,
inputs, membership and dependencies invalidate reverse dependents. Reused
outcomes retain exact values, diagnostics, traces and provenance. Source,
identities and the frozen source/storage schemas are never changed by calculation.

Discovery syntax is cached by exact source and lexing configuration; bindings
are rebuilt against the current structure and source-validated ledger. Current
cache state retains no previous snapshot chain and drops removed sources. The
graph is rebuilt with bounded links. This is incremental outcome and syntax
reuse, not a claim of an incrementally maintained graph or an edit-latency gate.
`parsedFormulas` counts successful discovery scans. `evaluatedCells` counts
processed non-reused data-cell nodes, including terminal and blocked diagnostics;
it does not count only engine evaluations. `reusedCells`, `dependencyLinks`,
`rangeCellVisits` and `scalarOperations` expose reuse and actual work.

Captured variables, lines, functions and closure values, units, manual rates,
provenance and clock/rate context are checked before reusing outcomes. Earlier
table snapshots are compared once per table. Empty/blank ranges also invalidate
when declared column interpretation changes, even when no member edge changes.
If the previous generation used kind-enumerating static-error probes, the next
recalculates outcomes conservatively while retaining cached discovery syntax:
shared probe-budget exhaustion must not make incremental diagnostics differ
from a fresh calculation.

Production limits are 4,000 populated cells per sheet, 100,000 distinct
cell/range dependency links per table generation, 1,000,000 range-cell visits
per table generation,
and 1,000,000 scalar operations per table generation. Scalar operations count
AST visits and numeric work, including nested custom bodies, range reductions,
unit conversions, comparisons, factorial/choice/root loops and internal numeric
helpers. This is a work counter, not a count of visible arithmetic operators.
The existing per-expression, syntax, integer and precision limits also apply;
custom bodies share the caller’s expression visit limit. Exceeding a population
or table-generation link, visit or scalar ceiling diagnoses
`resourceLimitExceeded` and throws instead of returning a partial generation.
Existing per-cell AST/arithmetic limits remain explicit cell failures, so
independent components can still calculate.
Cancellation is checked throughout graph and scalar work; a cancelled or failed
generation leaves its immutable predecessor untouched.

The source parser independently enforces the whole-sheet 4,000 populated-cell
and 1,048,576-byte admission limits, including tables hidden by dividers. The
calculator bounds current plus visible tables and accepts `sheetPopulatedCells`
for the M3 fold to supply the complete sheet population. Engine-only 10,000-cell
stress options do not weaken document admission. These remain provisional
resource ceilings, not evidence that integrated latency or memory goals pass.

## Verification

Separate subagents implemented task 5, wrote independent contract tests, reviewed
production changes, and performed final verification. Review findings were fixed
and regressions rerun before acceptance. The first full run found a test-only
nondeterministic dictionary selection; the assertion now selects the explicit
data-cell identity. The final complete run passed. Final evidence review then strengthened only the
million-visit test to isolate its range ceiling from scalar/link limits: it raises
those two ceilings, retains the default 1,000,000-visit cap, and asserts the
failure context is `.none` rather than scalar `.operations`. The strengthened
case passed in debug and release; broad full/sanitizer runs below precede this
assertion-only change. Production code is unchanged.

Environment: Apple silicon arm64, macOS 27.0 (26A428), Xcode 27.0
(27A266a), Swift 6.4. macOS 14 native behavior is not measured here.

| Check | Result | Local evidence |
| --- | --- | --- |
| Focused Table + custom functions | 272 engine tests passed | `/tmp/ganit-task5-focused-final.log` |
| Final full `swift test --parallel` | 900 tests passed, exit 0 | `/tmp/ganit-m2-task5-full-final.log` |
| ASan: GoldenCorpus, ArithmeticProperty, ParserFuzzSmoke and all Table tests | 288 selected tests passed; no sanitizer findings | `/tmp/ganit-m2-task5-asan.log` |
| TSan: incremental and context tests, including eight concurrent generations | 59 tests passed; no sanitizer findings | `/tmp/ganit-m2-task5-tsan.log` |
| Release Graph, Range, Context and Incremental tests | 190 tests passed | `/tmp/ganit-m2-task5-release-tables.log` |
| Strengthened isolated million-range-visit gate (debug/release) | Passed in both configurations | `/tmp/ganit-m2-task5-million-visits-debug.log`, `/tmp/ganit-m2-task5-million-visits-release.log` |
| Package manifest and all-product build | Passed (12 products, 26 targets) | `/tmp/ganit-m2-task5-package.json`, `/tmp/ganit-m2-task5-all-products.log` |
| Pinned strict formatter | Passed | `/tmp/ganit-m2-task5-lint.log` |
| Release app bundle | Built successfully | `/tmp/ganit-m2-task5-app-build.log` |
| Release app signature/entitlements/resources/App Intents verification | Passed | `/tmp/ganit-m2-task5-app-verify.log` |
| Bundled CLI arithmetic, assignment and incompatible-unit smoke | Passed | `/tmp/ganit-m2-task5-cli.log` |
| Whitespace check | Passed after source/test changes; repeated after documentation | `git diff --check` |

The tests are checked in: `TableIncrementalContractTests` adds 33 independent
contracts; `TableIncrementalTests` adds four implementation regressions. Earlier
M2 grammar, graph, range and context suites remain part of final full acceptance.

## M2 exit criteria

- Scoped grammar and collision suites cover ordinary syntax versus qualified
  operands, copy locks, source-validated bindings and references in every direction.
- Graph suites cover cycle participants, blocked readers, original causes and
  independent components. Release and sanitizer runs include both directions of
  the 10,000-cell chain on 512 KiB threads, with iterative evaluation and teardown.
- Range suites cover exact money/units, compatible/incompatible kinds, typed
  min/max, blanks/text/count, empty results and explicit conversion requirements.
- Context suites cover inherited functions, variables, lines, units, rate/clock
  snapshots and provenance, stale earlier tables and unsupported functions.
- Incremental suites compare edits with fresh calculations; value/formula edits,
  changed dependencies, appended/deleted rows, rules, headers, empty typed ranges,
  context and earlier snapshots invalidate necessary readers. Unrelated successful
  cells reuse outcomes without reparsing their discovery syntax. Shared-static
  diagnostics deliberately use the conservative replay described above.
- Resource suites exercise exact configured boundaries, production running-range
  link rejection, the million-visit budget, sparse expansion, aggregate/custom/
  factorial scalar work, sheet admission, cancelled edits and concurrent generations.

The recorded verification satisfies the M2 engine exit criteria.
No integrated edit-to-visible-answer percentile, resident footprint, launch/idle
budget, usability or native task acceptance is inferred from unit-test runtimes.

## Remaining acceptance gates

M3 must retain the calculator and pass previous snapshots, the complete sheet
population, captured scope in definition order, and current-generation earlier
table snapshots through the unified fold/scheduler. Wire `nextRecalculation` and
latest-generation commit/cancellation there. Structural edits must patch source
and ledgers transactionally and preserve identities.

Real input-method composition/commit/cancel and VoiceOver task completion remain
mandatory M4 gates. Native Find, cross-boundary copy, Return restoration,
regular/Markdown answer placement, narrow/scaled/RTL layout and repeated
text/grid transitions remain M5 gates. M6 retains supported-macOS, usability,
export, integrated performance, memory/idle and release verification. The linked
[M0 evidence](../../../Spikes/TablesM0/evidence.md) explicitly records these as
unverified; automated tests and an app build do not substitute for them.
