# M3 integration acceptance report

Date: 2026-10-03. Branch: `tables`. Starting commit: `4087b12`.

M3 implements structural source edits and table calculation in workspace
sheets. All five implementation tasks and final verification are complete.
Expanded editing and the inline preview remain M4 and M5 work.

## Source and storage

`TableSourceDocument` provides pure source transformations. `TableSourceEdit`
contains the resulting patches. `SheetSourceCoordinator` applies these patches
through the editor's text storage and document Undo manager.

Each edit preserves table, row and column identities unless it creates or
copies them. Scalar references follow their target identities. Range bounds
follow the surviving members. Deleted targets produce persistent broken
markers. Coordinate reuse and reload cannot repair these markers.

The source reconciler preserves unknown fields, unchanged record bytes and
record order. Formula rewrites update the source, binding fingerprint and
binding spans together. Tests cover row and column edits, endpoint deletion,
copy locks, fill, move, rule rebasing, empty tables and explicit overrides.
The structural corpus also runs 12 seeded sequences of 40 edits each.

Editor tests verify one named Undo step per structural operation. They check
source bytes and selection after Undo and redo. Storage tests verify save,
reload, plain source export and package export. Workspace tests verify
automatic save and the existing rule of one editor per sheet.

## Mixed-sheet calculation

`SheetCalculator` processes prose and table blocks in one evaluation pass.
A table captures the visible variables, functions, units, rates, line results
and preceding tables at its opener. Dividers reset table visibility. Table
source lines have no scalar values. They separate ordinary aggregate blocks.

Subsequent prose reads table values through qualified operands. The public
`TableResultSnapshot` API exposes immutable results by identity and source
span. Failure origins identify the original table cell. The interpretation
card can select that cell's source record or inherited rule.

The calculator reuses a table snapshot only when the model, captured scope,
visible tables, preceding revisions, populated-cell count and calculation
context permit reuse. Changes to an earlier assumption update table cells
and dependent prose. Added rows inherit column rules and update named ranges.

The existing scheduler cancels superseded requests and commits only the
latest result. Tables and prose use the same captured clock and rate context.
Clock-dependent tables contribute to the next recalculation time.

## Surface boundaries

Definitions and Quick Ganit do not calculate table blocks. Each block remains
in the source. Its first line shows an explanation. Quick Ganit identifies
Keep as Sheet as the path to workspace calculation. Services and Shortcuts
reject table blocks in a single-expression request.

Table source and table-reference failures cannot cause assistant requests.
Kept answers cannot replace table diagnostics. Titles use table names.
The search index uses table display text and schema 4. Metadata and package
manifest schemas remain 2. No support for previous formats was added.

Complete table deletion breaks references in dependent tables and prose in
one edit. Partial block damage preserves source and withholds dependent
projections until repair or Undo.

## Review corrections

The takeover review found three integration defects:

- The library's Duplicate Sheet command copied valid table IDs unchanged.
  It now calls the source duplication operation. Table, row, column and
  binding IDs change. Internal references follow the copies. Column widths
  transfer to the new table and column IDs. Tests compare calculated results
  before and after duplication and confirm that the original stays unchanged.
- Intermediate prose variables and functions lost inherited provenance.
  The evaluation pass now carries clock, exchange-rate and finance provenance
  through variables, consumed line references and captured functions. The new
  regression checks a clock-derived variable, a rate-derived variable, a line
  read and a custom function passed into tables.
- Deletion missed fresh table formulas without a saved binding ledger.
  It now checks each unchanged block and binds fresh references in the
  preceding scope. Only affected owners receive new source and ledger records.
  Tests verify Delete Table and direct block deletion. A new table with the
  original name cannot repair the broken references.

The corruption drill now checks the required new copy IDs. It still checks
exact bytes for malformed blocks and the original source. Frozen fixtures
were not changed. Existing independent structural contract suites remain part
of the final verification.

## Verification

All required M3 checks passed on the final source. Logs are local execution
evidence. The test suites and this report provide the permanent acceptance
record.

| Check | Result | Local log |
| --- | --- | --- |
| Full debug suite | 1,040 tests passed | `/tmp/ganit-m3-takeover-full-final.log` |
| Broad Address Sanitizer check before the final deletion correction | 427 tests passed | `/tmp/ganit-m3-takeover-asan.log` |
| Address Sanitizer after the deletion correction | 54 affected and calculator-corpus tests passed | `/tmp/ganit-m3-takeover-asan-final.log` |
| Optimized table suite | 420 tests passed | `/tmp/ganit-m3-takeover-release-tests-final.log` |
| Strict formatting check | Passed | `/tmp/ganit-m3-takeover-lint-final.log` |
| Release application build | Passed | `/tmp/ganit-m3-takeover-app-build-final.log` |
| Application bundle validation | Passed | `/tmp/ganit-m3-takeover-app-verify-final.log` |
| Packaged command-line calculator | Four checks passed | `/tmp/ganit-m3-takeover-cli-final.log` |
| Package metadata | Valid | `/tmp/ganit-m3-takeover-package.json` |
| Changed document links and whitespace | Passed | Checked before commit |

The command-line checks cover percentage arithmetic, ordinary variable scope,
a mixed sheet with a calculated column and subsequent table aggregate, and
rejection of incompatible units. Application bundle validation is not an
interactive launch or native interface acceptance.

## Remaining native acceptance

Automated AppKit tests exercise editor controls, document Undo, failure
navigation, clock scheduling and workspace save behavior. These tests do not
verify real IME composition, VoiceOver task completion, native Find routing,
expanded-grid use or inline-preview layout. M4, M5 and M6 must complete those
checks. M3 does not authorize a release of the table interface.

M4 must add a callback for committed evaluation results and connect the
expanded grid to the shared source coordinator. M5 must add inline block
presentation, Find navigation, copy, selection and scroll restoration, and
the Writing Tools policy. Resolve the development flag policy before merge
to `main` or release.
