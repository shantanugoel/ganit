# Calculation tables: implementation plan

Date: 2026-10-01; updated 2026-10-04. Status: M0 feasibility complete with
inline preview/Open Table selected; architectural decisions resolved in ADRs
0016/0017. M1 (source model, identity and safe storage) is complete on branch
`tables`: table block format v1 and metadata/manifest schema 2 are frozen with
fixtures, and its exit evidence passes. M2 is complete (see the execution record and
[engine evidence](../design/tables/m2-engine-evidence.md)). M3 is complete. It implements structural
source edits and table calculation in workspace sheets. The M3 acceptance report
records the [review and test results](../design/tables/m3-integration-evidence.md).
M4 implements expanded table editing. See the [M4 test report](../design/tables/m4-editor-evidence.md).
M5 embeds the preview in both sheet modes; its record is below with the
[M5 test report](../design/tables/m5-preview-evidence.md). M6 is complete: export,
mixed presentation, CLI modes, documentation and verification evidence are in
the [M6 release evidence](../design/tables/m6-release-evidence.md). This plan refines the [investigation](../design/tables-investigation.md)
and governs its unresolved details for this feature. It does not replace
accepted ADRs; M0 decisions and evidence are linked below.

## Outcome and scope

Add named, bounded calculation tables to regular and Markdown workspace
sheets. Users can keep assumptions above a table, calculate cells and columns
inside it, and refer to its results below. Expanded editing operates on the
same table and shares the document's source and Undo history. A table-first
new-sheet action is a template, not a separate sheet format or engine.

The first release includes typed inputs, formula cells, calculated columns,
A1 and structured references, ranges, row/column addressing, copy/fill locking,
cycle diagnostics, rectangular selection/paste, totals, focused editing and
lossless storage. Inline editing is a gated part of that release: if native
editing gates fail, ship an inline preview plus Open Table, preserving the
same block model. No dates or effort estimate until M0's spikes pass.

Comparisons, lazy `if`, conditional aggregates, lookup and text functions are
a following increment. Destructive sort, filtering, arbitrary forward
references between tables, cross-sheet dependencies, array spills, charts and
`.xlsx` compatibility are outside the first release. Unsupported formulas get
explicit diagnostics, not approximate substitutes.

## Compatibility scope

On 2026-10-04, the upgrade requirement changed. Convert schema 1 sheet
metadata and package manifests to schema 2. Keep the conversion rules in
`DocumentMigration`. Run library conversion before index recovery. Convert
package manifests in memory at import. Keep current readers strict.

Keep sheet source bytes unchanged. Keep original metadata in a separate
backup directory before replacement. Convert daily backup metadata too.
Show a startup message only when conversion is necessary. If a write fails,
stop startup and retry on the next launch. Do not convert unknown schemas or
add downgrade export. See [data migration](../storage/data-migration.md).

Atomic writes, source storage without data loss, malformed block isolation,
current format recovery, and ordinary calculator correctness remain required.

## Visual references and interaction requirements

The references are saved in the repository and do not depend on this chat:

- [Interactive concept](../design/tables/concept.html): use the bottom picker
  to switch between Within a sheet and Expanded table. Change quantities,
  prices or add a row to explore the fixed calculation rule.
- [Editable reference source and notes](../design/tables/README.md).

### Within a sheet

![Table between assumptions and dependent sheet calculations](../design/tables/within-sheet.jpg)

Preserve the ordinary writing surface around the table. Use quiet dividers,
system fonts, numeric alignment and existing Ganit number formatting. A
selected formula exposes its source and referenced cells. Addresses appear
when useful, rather than making a permanent spreadsheet frame dominate prose.
The block can use the available editor width; the answer-column rule must
not cut through it. Below-table results use the sheet's existing regular or
Markdown answer placement.

### Expanded editing

![Expanded editing of the same table with row and column addresses](../design/tables/expanded-table.jpg)

Use the editor pane for the selected table with stable headers, a compact
formula field and a discoverable Return to Sheet action. Restore the previous
prose cursor, table selection and scroll position. The illustrated formula
field is read-only in the concept; production editing, reference picking,
column-formula controls, error cards and Return to Sheet are required work.

The concept is an interaction/layout reference, not production code, a native
screenshot, a storage-format example or a general formula parser. Its fixed
INR arithmetic, simplified validation and controls do not define engine rules.
Map the visuals to [Ganit's semantic visual system](../design/visual-system.md).

## Contract to implement

### Document and scope

1. Recognize explicitly delimited table blocks before ordinary line syntax
   or Markdown prose classification. Plain Markdown pipe tables stay prose.
2. Preserve physical source-line numbering. Each table source line has no
   ordinary scalar answer: `line N`/`@N` targeting it fails explicitly and
   points to qualified table references instead.
3. Preserve existing top-to-bottom scope, redeclarations, custom-unit/rate/
   function closures and divider resets. Capture the visible scope when the
   table begins. References to later prose or later tables fail in v1.
4. Inside one table, references may point in any direction; graph order,
   rather than row order, determines evaluation. Later tables and ordinary
   lines can read visible earlier tables.
5. Table names are case-insensitively unique within a sheet, even across
   dividers. Dividers reset table visibility along with ordinary local scope.
   Column names are unique within their table. Headers can contain spaces,
   currency names and unit words without becoming variables or units.
6. A table ends the ordinary aggregate block before and after itself without
   resetting variables. Its cells and visual totals never silently join bare
   `sum`, `subtotal` or `previous` in prose. Use qualified references to consume
   them. Inside table formulas, diagnose bare aggregate/`previous` keywords;
   explicit range arguments are required.
7. V1's grid UI is a workspace feature. Definitions remains a declaration
   surface; reject tables there rather than accidentally exporting table
   values globally. Quick Ganit must identify pasted table blocks and offer
   an explicit workspace path or a clear unsupported-view response. It must
   not calculate raw table rows as ordinary lines or lose their source.

### Cell input and values

- Distinguish blank, literal text, typed literal input, formula source,
  inherited column formula and an explicit override. Formula cells start
  with `=`. Empty input is blank, not zero. A blank override is distinguishable
  from clearing an override and inheriting the column rule again.
- Start with explicit text versus value column input policies. Value inputs
  accept complete supported literals: numbers, percentages, money, quantities
  and temporal values. Arithmetic such as `1-2` requires `=`; suggest that fix
  instead of interpreting it as a date or silently switching it to text.
  Column unit/currency defaults affect interpretation and therefore belong in
  canonical source, not just display metadata. Use existing locale policy.
- Keep ordinary scalar values as `EngineValue`. A separate cell/operand layer
  carries text, blank, range views and failures. General string and boolean
  expression support is not required for v1.
- Arithmetic on blank/text is an error. Range `sum`, `average`, `median`,
  `min` and `max` skip blank/text, propagate failed cells and require compatible
  scalar kinds. Preserve exactness, dimensional checks and currency checks;
  require explicit currency conversion. Typed min/max need implementation
  and tests; current numeric-only paths are not automatically sufficient.
- Preserve existing empty numeric `sum` → `0`. An empty typed column can
  produce its declared typed zero when its kind admits an additive zero;
  otherwise diagnose the unsupported aggregation. Empty average/median/min/max
  is an error regardless of column type. Reference failure is never an empty
  range or zero.
- Preserve existing explicit-list `count(...)` semantics. In v1, `count(range)`
  counts nonblank scalar values, including money/units/temporal values, and
  fails on formula errors; text is excluded. Selection shows selected cell
  count separately. Document this Ganit behavior instead of claiming Excel
  COUNT compatibility; a distinct nonblank count can follow later.
- Formatting never changes stored values. Ranges/derived totals must not
  substitute rounded or displayed text into formulas. Carry approximation,
  rounding, currency-rate and clock provenance through dependencies.

### Addressing

These spellings follow the accepted M0 reference contract in ADR 0016;
the production parser and collision corpus are M2 work. Examples assume header row 1, first data row 2.

| Form | Meaning |
| --- | --- |
| `=B2 * C2` | Scalars within the current table |
| `=$B$2`, `=$B2`, `=B$2` | Both, column-only or row-only locking during copy/fill |
| `=sum(B2:D6)` | Rectangular range |
| `=sum(C:C)` | Bounded data column; excludes header and visual totals |
| `=sum(2:2)` | Bounded data row; does not exclude the formula cell if it lies there |
| `=[@Qty] * [@[Unit price]]` | Current row's named columns |
| `=sum(Items[Amount])` | Current data membership of a named column |
| `=Rates!B2`, `=sum(Rates!B2:B8)` | Qualified cells/ranges in a visible earlier table |
| `=sheet[B2]` | Inherited ordinary variable named B2, rather than a cell |
| `cost = sum(Items[Amount])` | Qualified table operand in a later ordinary line |

Reserve `sheet` as a table identifier for the inherited-scope qualifier, not
as a new forbidden ordinary variable name. Outside table formulas, bare `B2`
keeps its current variable meaning; only explicit table-qualified references
enter the added grammar. Add escaping rules for punctuation in headers and
table identifiers. Do not silently reinterpret `$` money, `!` factorial,
time/label `:`, bitwise `|`, `@N`, or completion queries.

In table formulas accept case-insensitive aliases for the supported built-in
function set, so `SUM` and `sum` work alike. Preserve ordinary-sheet dispatch
and existing custom-function naming. Diagnosing bare aggregate keywords must
not reject an inherited variable with that name; `sheet[count]` makes that
intent explicit when it would otherwise be ambiguous.

Scalar header references return text. The totals footer is a summary surface
without a numbered data row; its configuration is persisted, and its operands
read data rows only. Refer to its equivalent named aggregate in prose. A
whole row/column that includes the formula itself is a cycle: never special-
case it by removing the current cell. A1 addresses outside table bounds fail;
there is no infinite worksheet or automatically expanding reference target.

### Structural edit semantics

| Operation | Required behavior |
| --- | --- |
| Edit a value/formula | Keep table/row/column identities; recalculate dependents |
| Insert row/column | Existing scalar references follow targets, including `$` references; insertion strictly inside a rectangular range expands it, insertion before it shifts it, insertion just outside it does not extend it |
| Append a row | Named/whole-column ranges grow; a finite rectangle does not grow merely because a row was appended after it |
| Delete a scalar target | Persist a broken-reference token with original target identity; reuse of its old coordinate cannot repair it |
| Delete inside a rectangle | Remove that membership and shrink surviving bounds; if no referenced data survives, persist a broken range |
| Delete a rectangular endpoint | Surviving included rows/columns become the new bounds; do not accidentally include an adjacent outside row |
| Rename table/column | Rewrite bound source references in the same Undo transaction; ordinary text/comments are untouched |
| Copy/fill formula | Translate unlocked axes from source cell to destination; locked axes stay fixed; out-of-bounds translations become persistent broken references |
| Move formula/cell | Preserve referenced identities; do not apply copy translation |
| Copy table/sheet | Mint appropriate new table/row/column IDs and rebind references internal to the copied set; preserve external references only when their targets remain visible, otherwise mark broken |
| Change column rule | Update inherited cells; preserve and visibly mark per-cell overrides |
| Undo/redo | Restore source, IDs, references and selection as one coherent document edit; then recalculate |

Structured column names stay attached to the same column during v1 copy/fill;
only a current-row qualifier changes its row context. This is a documented
simplification of Excel's structured-reference fill variants. A relative A1
column-rule template is anchored to the first data row and instantiated with
the same copy rules, including newly appended rows. Preserve relative offsets
and locked target identities when inserting/deleting the anchor row; rebase
the template as part of that edit. An empty table retains a virtual row-2
template anchor and instantiates its rule when data is added. Test zero-row,
one-row and first-row insertion/deletion cases explicitly.

Use a versioned Ganit clipboard payload with source origin and formula/input
policy for internal copy/fill; preserve plain TSV as the interoperable fallback.
An arbitrary external formula string has no trustworthy source origin: bind
it at the destination after explicit formula-paste selection. V1 rectangular
move applies within the same table; cross-table moves are deferred until target
qualification and inherited-scope changes have an explicit contract.

V1 has no destructive sort or arbitrary row move. A later sorting increment
must settle the tension between references that follow records and rectangular
ranges before enabling it. View-only sort/filter does not change canonical
address order; ordinary aggregates still include hidden data.

### Identity in source and after reload

Use persistent `TableID`, `RowID` and `ColumnID`; a data-cell identity is their
tuple, avoiding an extra UUID for every cell. Header identities are distinct.
Never use session `LineID` or a physical row index as durable identity.

The versioned block stores readable inputs/formulas, ordered IDs, semantic
column settings, column rules/overrides and a reference-binding ledger. The
ledger associates formula occurrences with target identities and copy flags;
readable A1/name source alone is insufficient to stop deleted references from
rebinding after reload. Successful structural edits rewrite both together.
Broken references are explicitly represented in source, with repair commands.
The exact ledger encoding and broken-marker spelling are M0 decisions.

Anchor table-formula bindings by owning cell/rule identity, not a global text
offset. Ordinary prose references use the existing rewrite-and-persist pattern:
successful table address rewrites and deleted-target markers survive reload
as source. Prose lines do not gain persistent `LineID`s for this feature. M0
must prove both paths, including duplicate formula text in different locations.

Bind a freshly typed/pasted reference to its current address. Reuse persisted
bindings only when their formula-source fingerprint matches. A manually
edited formula invalidates its old bindings; do not attach a stale occurrence
ordinal to different text. Diagnose duplicate IDs, conflicting ledgers and
malformed blocks without mutating their source. New IDs are minted only for
deliberate creation, duplication or an explicit repair, not on every parse.

Lossless parse/serialize preserves untouched UTF-8 text and line endings.
Source commands patch relevant spans; parser recovery retains the complete
malformed/unknown block and stops its body from being evaluated as prose.
Plain source export includes identities/bindings; values-only Markdown/CSV
exports are explicitly lossy presentations.

## Architecture and ownership

Keep the existing module boundaries and deterministic engine. Proposed new
type names below describe responsibilities, not mandatory API names.

| Layer | Work |
| --- | --- |
| `GanitEngine` | Block source map/codec, typed references and range operands, graph evaluation, identities/bindings, structural-edit transformations, table result snapshots |
| `GanitFormatting` | Cell/column formats, range errors, interpretation/provenance, source-reference completions |
| `GanitEditorUI` | Document source-edit coordinator, expanded/inline grid controllers, cell selection, reference picking, summary bar and source-mapped projection |
| `GanitDocuments` | Current-format atomic storage, recovery, backups, export/import and identity remapping |
| `GanitWorkspaceUI` | Insert/Open/Return commands, table-first template, focused-view restoration, title/search integration and multiwindow synchronization |
| `GanitSystemIntegration` / CLI / Quick UI | Shared evaluator and explicit scalar/table output contracts |

Extend the sheet evaluation result with a table-result collection keyed by
identity and source span while retaining per-physical-line results. Refactor
the existing top-to-bottom fold to visit text/table blocks with one live scope
and one physical-line map. Do not evaluate separate text fragments using fresh
`SheetCalculator`s: that loses references, redeclarations and aggregate state.
Keep a fast path and existing cache instrumentation for table-free sheets.

Each table calculator binds references, discovers dependencies, identifies
cycles and evaluates the acyclic graph. Discover references using a dedicated
syntax/binding pass before Ganit's value-kind-directed parse. Defer parsing
percentage/unit phrases until dependency kinds are available. Cache parsed
ASTs by source and operand kinds, outcomes by inputs/context, and range nodes
by membership. Include inherited custom functions and captured dependencies.

Use an iterative graph walk/SCC algorithm with reverse dependencies and
cancellation; recursive 10,000-cell chains must not overflow the stack. Report
cycle participants, blocked dependents and original failing cell addresses.
Independent components still calculate. Recheck missing-reference bindings
when structure changes, so adding a previously missing named column can
repair a fresh unresolved name without reviving a deliberate deleted marker.

Ranges are bounded views over outcomes, with shared membership/dependency
nodes; do not convert a range into thousands of positional function arguments
or repeat its cell-edge set for every reader. One generation uses one clock,
currency-rate snapshot and inherited-scope snapshot. Reuse latest-generation
commit, clock-boundary scheduling and cancellation in the current scheduler.

Move authoritative source-edit orchestration out of `NSTextView` ownership
only as needed. Text and grid edits must pass through the same document Undo,
source update, reference rewrite, autosave and evaluation pipeline. Projections
are derived and never independently saved. Multiwindow updates must refresh
both projections and preserve the existing document conflict policy.

No automatic assistant fallback for table syntax/errors and no per-cell request
fan-out. Keep formula computation local. Any later explicit selected-cell
assistant action follows the existing opt-in behavior and marks provenance.

## Milestones and exit criteria

Each milestone should be a reviewable change or a small series of changes.
Keep unfinished behavior behind a development flag until all v1 gates pass.

### M0 — Close architectural questions with disposable spikes

- [x] Prototype a lossless versioned block plus identity/reference ledger.
      Exercise Unicode, CR/LF/CRLF, quotes, brackets, multi-line text, decimal
      commas and formula `|`. Check size overhead against the 1 MB source limit.
- [x] Prototype a rightward/downward dependency, a cycle with an independent
      valid component, and a 10,000-cell chain using Ganit arithmetic.
- [x] Prototype an expanded native grid edit through document Undo and a
      source-mapped inline preview. Verify automated focus, cross-boundary copy,
      mapped Find selection, marked-text retention and accessibility labels;
      inspect the prototype divider. Choose preview/Open Table. Full native
      task acceptance on the integrated editor remains mandatory in M4/M5.
- [x] Specify reference grammar/escaping, inherited-variable qualifier,
      ledger/broken-marker encoding and exact range transformation rules.
- [x] Resolve ADRs for table semantics/editor ownership and table-source/
      storage. The experimental wire format is frozen only after
      M1 fixtures and validation; architecture acceptance is not a format freeze.

M0 execution evidence is in [the disposable spike report](../../Spikes/TablesM0/evidence.md).
Run instructions, CR/LF/CRLF round-trip fixtures, recovery examples, a native
preview capture and dependency traces are checked in alongside the isolated
`GanitTablesM0` executable. The shipping targets do not depend on it.

[ADR 0016](../adr/0016-table-semantics-and-editor-ownership.md) specifies the
semantics, reference escaping and precise transformation rules. [ADR 0017](../adr/0017-table-source-and-storage.md)
specifies the ledger approach, current metadata/manifest schema 2, and atomic
storage/recovery. Backward compatibility and migration are excluded. Both ADRs
are **accepted architectural decisions**. M1 validated and froze the production
wire format as [table block version 1](../storage/table-blocks.md); the
disposable spike encoding is not a public format. Source byte measurements set a **4,000 populated-cell provisional
ceiling**, independently subject to the existing 1 MB source limit; the engine
still proves a stack-safe 10,000-node chain. M2/M6 must validate the remaining
resource budgets and full edit-to-visible latency.

The explicit editor choice is **inline preview + Open Table**, with expanded
AppKit editing. Automated native field commits, source/Undo/redo, deletion and
disk reload, cross-boundary copy, mapped Find selection, Return focus and
marked-text simulation pass. A derived inline native preview is captured and
source-mapped, and its divider skips the table. Real input-method composition,
VoiceOver task completion, native Find-panel navigation, both sheet modes and
integrated answer placement have **not** been verified. These are mandatory
**M4/M5 acceptance and M6 release gates**, rather than blockers for M1 source
and storage implementation. This explicitly revises the original M0 sequencing:
M0 establishes feasibility and selects the permitted preview fallback; full
editor task verification runs when the integrated editor exists. No unrun test
is marked passed, and release gates are not waived. See the report for the
exact task acceptance runs required. No user decision is needed to begin M1,
and no production schema constants or document files were changed.

**Exit:** round-trip fixture examples, dependency traces, native editing proof,
measured size/latency, and an explicit inline-edit versus preview decision are
recorded. No unresolved semantic question is delegated to incidental UI code.
If inline editing fails, accept the documented preview/Open Table fallback.
If source recovery, exact arithmetic or shared Undo fails, revise the design
before proceeding.

### M1 — Source model, identity and safe storage

- [x] Implement block segmentation, source-coordinate mapping, lossless codec,
      IDs, binding validation and malformed/unsupported-block diagnostics.
- [x] Add frozen fixtures and readers/writers for the single current format:
      metadata/manifest schema 2, as selected in ADR 0017. Reject unsupported
      schemas explicitly. Use the central schema 1 migration module.
- [x] Use atomic source/metadata/package writes and retain ordinary current-
      format backups. Test interrupted writes and keep original metadata
      before migration. No older reader publication barrier is required.
- [x] Recover missing/corrupt metadata in the current schema from canonical
      source without losing IDs, bindings or malformed blocks. Unknown table
      versions must stay quarantined from ordinary calculations.
- [x] Support current-format package import/export and exact plain-source
      import/export. Do not add downgrade export or schema conversion.
- [x] Make malformed tables retainable/saveable without source loss; editing
      must not replace an invalid table with the last valid projection.

**Exit:** interrupted atomic writes preserve a complete committed source.
IDs, broken references and formulas survive current-format save/reload,
plain-source recovery, current-format backup restore and corruption drills.
Current-format fixtures load; unsupported schemas are rejected explicitly.
No older-format reader, upgrade/downgrade or migration rollback is required.

### M2 — Formula grammar, graph and typed range operations

- [x] Add scoped AST/reference forms, bindings, inherited-scope reads and
      typed cell/range operands. Verify supported ordinary syntax and arithmetic
      alongside table formulas; no separate legacy parser or evaluator path.
- [x] Implement iterative graph evaluation, SCC diagnostics, blocked-result
      propagation, cycle paths and original-cause source ranges.
- [x] Implement range aggregates, empty/type/error rules, whole-row/column
      bounds and data-only named membership; audit typed min/max explicitly.
- [x] Reuse exact arithmetic, conversions, functions, rate/clock context and
      provenance. Diagnose unsupported/bare table functions explicitly.
- [x] Add dependency invalidation, range-membership invalidation and resource
      limits. Start with M0's provisional per-sheet 4,000 populated cells,
      100,000 dependency links and 1,000,000 range-cell visits per generation;
      validate/tune these in M0/M6. Keep the existing 1 MB source limit and
      arithmetic/syntax limits. Diagnose limits; never truncate calculation.
      Bound total scalar operations per table generation as well as per cell,
      so many individually legal heavy formulas cannot evade the work budget.

**Exit:** engine/corpus cases cover references in every direction, exact
money/units, compatible/incompatible ranges, empty inputs, dynamic column
membership, cycles and independent results. A 10,000-cell chain is stack-safe;
an edit invalidates the necessary dependents without reparsing unrelated cells.

### M3 — Structural edits and mixed-sheet evaluation

- [x] Implement pure source transformations for creation, insertion/deletion,
      rename, formula copy/fill/move, table/sheet duplication and column rules.
      Persist automatic rewrites and broken markers in the triggering edit.
- [x] Apply every operation in the structural-edit contract, including range
      endpoint deletion and copy-lock behavior. Reject ambiguous partial moves
      rather than guessing; basic contiguous rectangular moves are sufficient.
- [x] Integrate table evaluation into the existing fold/cache, keeping inherited
      definitions, dividers, physical line references and aggregate boundaries.
- [x] Extend result snapshots/scheduler and failure navigation; check ordinary
      line-reference renumbering never scans table formula or identity text as
      prose. Table formulas' deliberate `@N` reads of earlier prose still follow
      their targets through the unified transformation path.
- [x] Verify definitions/Quick boundaries, assistant suppression, title
      derivation and search. A table-first sheet should be titled from its
      display name, not an identity/codec record.

**Exit:** insert/delete/rename/copy/fill → Undo → redo → save → reload tests
preserve intended targets. Added rows inherit the column formula and update
later prose. Changing an earlier assumption recalculates cells and downstream
results. Supported ordinary/Markdown/definitions calculations remain correct.

### M4 — Expanded native table editing

Carry forward [M0 native acceptance tasks 1–2](../../Spikes/TablesM0/evidence.md):
real input-method composition/commit/cancel and VoiceOver task completion.
Automated marked-text/label checks are supporting evidence, not substitutes.
The integrated controller has native composition and basic accessibility
results. The user requested basic VoiceOver checks for this phase. Spoken
VoiceOver tasks and CJK candidate-window checks remain release checks. See
the [M4 test report](../design/tables/m4-editor-evidence.md).

- [x] Build a view-based AppKit grid using reused rows/cells and the existing
      visual tokens/formatters. Add virtualized rendering before large-table QA.
- [x] Implement cell-versus-edit selection states, rectangular selection,
      keyboard navigation, commit/cancel and document Undo. Test IME composition
      without recalculating or rewriting marked text before commit.
- [x] Implement editable formula field, reference picking/dragging, completion
      and source/target highlighting. During formula editing, picking a cell
      inserts a reference rather than unexpectedly committing or moving focus.
- [x] Add explicit column-rule creation, per-cell override indication/reset,
      row/column add/delete, copy values/formulas, rectangular TSV paste/fill,
      totals and typed selection summaries.
- [x] Add Show Interpretation, full-precision copy, broken-reference repair and
      original-failure navigation. Pending evaluation must not display an old
      answer as if it belongs to newly edited input.
- [x] Implement Open Table/Return to Sheet state restoration and multiwindow
      projection synchronization through the source coordinator.

**Exit:** keyboard and VoiceOver users can create a table, enter data, write a
column formula, pick a reference, paste a rectangle, recover an error, undo and
return to prose. No separate grid Undo/source store or eager per-cell views.

### M5 — Embedded presentation in both sheet modes

Carry forward [M0 native acceptance tasks 3–4](../../Spikes/TablesM0/evidence.md):
native Find-panel routing, cross-boundary copy and state restoration; regular/
Markdown answer placement, narrow widths, scaled text and RTL. Repeat real IME
and VoiceOver checks across text/grid transitions. These remain release gates.

- [x] Reserve mapped block layout without object-replacement characters in
      canonical source. Make surrounding text selection, caret movement,
      scrolling and answer placement work at both table boundaries.
- [x] Add Insert Table and rectangular-paste conversion with deliberate header/
      type selection. Keep ordinary multi-line paste unchanged unless chosen.
- [x] Render inline totals/errors and formula inspection. If M0 selected the
      fallback, make the inline preview accessible and use Open Table for edits.
- [x] Integrate Find, cross-boundary copy, printing/source inspection, narrow
      windows, scaled text, right-to-left content and assistive navigation.
      Search results must open the relevant cell in expanded mode when needed.
- [x] Recheck native marked text, responder-chain commands and Undo after
      moving between text and table editing. Support normal and Markdown answer
      placement without changing table formula semantics.

**Exit:** repeat M0's native editing checks on the integrated controller.
If direct editing fails them, use the preview fallback; do not waive source,
IME, Find, Undo or accessibility correctness to match a screenshot.

### M6 — Export, verification and release readiness

- [x] Export/import `.ganit` and plain source losslessly; expose selected-table
      TSV/CSV values and explicit formulas mode with locale/header handling.
      Define a documented safe CSV/text treatment for literal leading `=`,
      `+`, `-` or `@` when another app might interpret them as formulas.
- [x] Update HTML, PDF/print and Quick Look to render mixed blocks, with repeated
      table headers on continued pages, readable units and explicit failures.
- [x] Define documented scalar and structured table-result CLI output modes;
      do not flatten cells into unrelated physical-line answers or add legacy
      output adapters. Single-expression
      Services/Shortcuts retain their scalar contract and diagnose table input.
- [x] Complete the verification matrix below, frozen-format/grammar docs,
      Help/completions, recovery guidance, release notes and sample sheets.
- [x] Run task-based usability checks and performance gates on representative
      supported macOS versions, including macOS 14. Keep feature initialization
      lazy for ordinary sheets and Quick Ganit. (Checks ran on this macOS 27
      machine only, as the operator directed; the macOS 14 matrix rows and the
      real-participant study remain release activities.)

**Exit:** all mandatory rows in the verification matrix have recorded evidence;
the selected inline mode passes native editing gates; ordinary workflows meet
existing budgets. Only then remove the development flag and mark the feature
implemented in documentation. Publish/ship remains a separate release action.

## Verification matrix

| Concern | Verification / likely suite |
| --- | --- |
| Current calculator correctness | Engine golden corpora, variable/line-reference/Markdown/definitions suites; scoped syntax cases for B2, `$`, `!`, `:`, `|` and `@N`; no cross-version compatibility matrix |
| Source fidelity and IDs | New block/codec tests with untouched-byte round trips, Unicode/line endings, duplicate IDs, stale ledgers, malformed and unknown blocks |
| Formula correctness | New table parser/evaluator fixtures and seeded properties for exact values, range versus scalar reductions, directionality and error propagation |
| Reference integrity | New transformation/property tests with randomized edits; replay inverse edits and reopen source to check targets and copy flags |
| Scope and snapshots | SheetCalculator/scheduler tests for redefinitions, dividers, earlier tables, superseded generations, cancellation and clock/rate changes |
| Storage and recovery | Current-schema frozen-format/fault/recovery tests; atomic writes, missing/corrupt metadata, current-format backup restore and duplicate import |
| Native editing | GanitEditorUI integration tests for cell/edit/reference-pick states, shared Undo, copy/paste and Find; real IME, VoiceOver listening and RTL review |
| Presentation/export | Mixed-sheet renderer/Quick Look fixtures; inspect multi-page print/PDF, display/full precision, invalid cells, CSV literal/formula cases |
| Scale and footprint | Benchmarks with 1,000 populated ordinary cells and 10,000 dependent cells; range membership edits, cancellation, memory and idle CPU |
| Real jobs | 5–8 participants: budget/per-person cost, unit-aware materials estimate and monthly figures; observe creation, formula picking, growth and error repair |

Use the existing P95 16 ms ordinary / 50 ms stress edit-to-visible-answer
goals as provisional table targets. Record hardware, release build, dataset,
populated cell/edge counts, measured percentile and resident footprint. Run
long-chain, many readers of one large range, dense dependencies, structure
changes and alternating text/table edits. If a gate fails, fix or explicitly
reduce/review the documented limits; do not relabel unmeasured goals as results.
Table-free sheets and Quick Ganit retain current launch, memory and idle gates.

## Re-review record

Reviewed again against the current calculator, parser/value model, source
editing/scheduler, storage/write order, recovery and headless integration on
2026-10-01. This is a design review, not verification of an implementation.

| Issue found in the investigation | Resolution in this plan |
| --- | --- |
| IDs alone do not preserve bindings after reload | Persist a source-validated reference ledger and broken targets; distinguish new text from existing bindings |
| Finite rectangles versus growing columns were underspecified | Explicit insertion/deletion/append rules; data-only growing named columns; destructive sorting deferred |
| A named sheet variable can look like an address | Scoped parsing and explicit `sheet[B2]`; ordinary bare B2 is a variable |
| Blank/text/count rules could silently inherit Excel coercion | Define scalar errors, range policies, empty results, override blanks and Ganit count behavior |
| Type-directed parsing can precede dependency availability | Separate reference discovery/binding from typed parsing and graph evaluation |
| Interrupted writes must retain complete canonical source | Atomic writes and recovery; central schema 1 conversion with original metadata backups |
| Missing/corrupt metadata must not lose table source | Rebuild current-schema metadata from canonical source; retain malformed/unknown blocks |
| Fragment-by-fragment evaluation would reset sheet state | Integrate blocks into one scope/physical-line fold and retain ordinary-sheet cache instrumentation |
| Raw table lines could enter aggregates or assistant fallback | Explicit block boundaries, non-scalar table lines and no automatic table assistant fan-out |
| Expanded grid could create a second source/Undo owner | One source coordinator, derived projections, coherent Undo and multiwindow synchronization |
| Visuals omit several production interactions | List formula editing, column rules, repair, selection/paste and Return to Sheet explicitly |
| Empty/first-row tables and external formula paste have special binding behavior | Define virtual template anchors, rebase rules, internal clipboard origins and explicit external formula paste |
| Inline native integration may not pass usability/accessibility gates | Keep expanded editing as the foundation and allow accessible inline preview as a bounded fallback |
| Existing line-oriented exports/headless answers could flatten tables | Block-aware renderers and explicit structured CLI output, preserving old output for old sheets |

M0 source/binding fixtures, graph traces, measured limits and editor choice are
recorded in the [evidence report](../../Spikes/TablesM0/evidence.md) and accepted
ADRs 0016/0017. M1 is complete; no architectural approval is required to start M2.
Resource limits remain provisional until integrated M2/M6 measurement. Native
task checks are explicitly tracked under M4/M5 and the release matrix; no
unverified acceptance result has been converted into a pass.

## M2 durable execution status

Updated 2026-10-03. Worktree `/Users/shantanugoel/.codex/worktrees/tables-m0/ganit`,
branch `tables`; clean starting HEAD `4a1e765`. This execution completed M2
only. The M3 execution record below gives the current status. All M2 exit criteria have recorded
[engine acceptance evidence](../design/tables/m2-engine-evidence.md).

- Task 1 (scoped grammar/bindings/operands): implement → independent review →
  test complete, approved; committed `990e601`. Push required reconciliation
  with remote `b21c184` (pre-existing rebased M0/M1 history). Independent
  range-diff and exact-tree review verified all remote work preserved; merge
  source tree equals `990e601`. Both conflict sides backed up under
  `/tmp/ganit-m2-reconciliation-backup`. Merge `8afef34` pushed successfully.
  Shared Parser token hook,
  scoped binding/typed operand foundation; no IDs minted or source re-encoded.
  Ordinary syntax/collision/visibility/ledger corpus includes time precedence:
  existing lexer time tokens remain temporal; `Items!12:30` selects data rows.
  Baseline repairs preserve prefix-toggle LF/CR/CRLF and wait for completed
  assistant test output. All review findings resolved with regressions.
  Verification: full suite **809 passed** before final nested-percentage-only
  scanner fix; final affected **23 grammar + 2 editor tests passed** (editor
  toggle parameterized for three line endings); package dump, all-product
  build, pinned formatter and whitespace checks passed. Evidence logs:
  `/tmp/ganit-m2-task1-full-final.log`,
  `/tmp/ganit-m2-task1-affected-final.log`,
  `/tmp/ganit-m2-task1-build-final.log`.
- Task 2 (iterative graph/SCC): implement → review (3 rounds) → test complete,
  approved; committed (see git log "iterative table graph"). Lazy stable-identity
  cell nodes plus shared symbolic range-membership nodes; iterative Kosaraju SCC,
  closed directed cycle witnesses, blocked readers distinct from participants,
  independent components calculate. Original causes are an interned
  `TableCauseSet` DAG (O(inputs) per reader, cached flatten, structural
  provenance equality/hash, iterative deinit). Earlier snapshot model is
  authoritative; own static errors outrank blocked inputs (`staticFailure`,
  budgeted by `maximumStaticCheckParses`); `inheritedFailure` code; rule
  templates bound once. Range readers stay `unsupportedRangeOperation` until
  task 3. Evidence: full suite 751 passed (`/tmp/ganit-m2-task2-full-r3.log`),
  CI ASan + TableGraph ASan/TSan pass, strict lint pass, release TableGraph
  pass; 41 TableGraph tests incl. 10,000-cell up/down chains on 512 KiB
  threads and ratio-based linearity checks at 4,000 cells.
  Carried forward: m5 running-range O(rows²) edges → task 5 link budget;
  `originCount`/`origins(prefix:)` still flatten fully → M4 UI should query
  visible/selected cells only (or add a cheap prefix).
- Task 3 (range aggregates): implement → review (2 rounds) → test complete,
  approved; committed (git log "range aggregates"). Supported single-range
  aggregate calls (sum/total/average/avg/median/min/max/count, any case) are
  found in tokens, reduced first (members collected once per shared range
  node, reductions cached per node+function) and collapsed into a synthetic
  operand with the reduced kind before the kind-directed parse, so `of`/unit
  phrases work. Typed range min/max ordering (exact numbers, %, compatible
  units, same-currency money, temporal, unambiguous periods); explicit-list
  min/max unchanged. Empty: count 0; average/median/min/max `.emptyRange`;
  sum 0 or declared typed zero, else `.unsupportedAggregation`. Own syntax/
  keyword/inherited errors outrank reduction failures. `rangeCellVisits`
  counted for task 5. Evidence: full suite 811 passed
  (`/tmp/ganit-m2-task3-full-final.log`), ASan/TSan/release TableRange|Graph
  pass, strict lint pass; `TableRangeContractTests` 32 + `TableRangeTests` 29.
  Carried forward to task 4: `TableCalculator.visibleCustomFunctionNames` hook
  must receive inherited custom functions (and pass them to evaluation).
- Task 4 (context reuse): implement → review (3 rounds) → test complete,
  approved; committed (git log "inherited sheet context"). `TableFormulaScope`
  captures functions (+ `functionProvenance`; exact per-definition helper for
  the M3 fold, linear batch helper), `@N` line outcomes, manual rates,
  `TableScopeUnits`, `tableLines: IndexSet` (all table source lines at/above),
  variable/line provenance. One context per generation (`isCurrent(in:)`,
  stale earlier snapshot → `.staleTable`; inherited scope NOT covered — M3
  must fingerprint it). `TableCellProvenance` (clock/rates/finance) flows
  through cells, ranges, earlier tables, inherited vars, `@N` and closures;
  `nextRecalculation`. Tables never convert currencies implicitly
  (`convertsMixedCurrencies: false`). `.unsupported` for comparisons,
  deferred/non-deterministic functions, assistant prompts (never evaluated);
  `tableLineReference`/`laterLineReference`; unknown functions and custom vs
  built-in dispatch match ordinary sheets. Evidence: full suite 862 passed
  (`/tmp/ganit-m2-task4-full.log`), CI ASan + Table ASan pass, lint pass,
  `TableContextContractTests` 29 + `TableContextTests` 22.
  M3 carry-over: fold fills scope fields in definition order, wires
  `nextRecalculation`/`isCurrent` and an inherited-scope fingerprint.
- Task 5 (dependency/range-membership invalidation and resource limits):
  understand → delegated implementation → independent review → independent test
  complete, approved. Immutable previous-snapshot reuse (same calculator or copy),
  reverse-dependent invalidation, bounded current syntax/outcome cache, refreshed
  bindings/membership; generation limits 100,000 links / 1,000,000 range visits /
  1,000,000 scalar work units, plus existing 4,000-cell and source admission.
  Scalar accounting includes nested custom calls, numeric loops, conversions and
  reductions; custom bodies now also share the caller's per-expression limit.
  Review fixes cover empty typed-zero defaults, earlier-table comparison cost,
  shared static-probe budget replay, conversions/trig and sticky cancellation.
  33 independent contracts + 4 implementation regressions. Final verification:
  **900 full-suite tests passed**, ASan 288, TSan 59 (concurrent generations),
  release Table 190 including 10,000-cell small-stack chains; package dump,
  all-products build, strict lint, release app build/verification, CLI smoke and
  whitespace passed. Final evidence review strengthened the million-visit test
  to isolate it from scalar/link limits; affected debug/release reruns passed
  (production unchanged). Logs `/tmp/ganit-m2-task5-*.log`; focused log
  `/tmp/ganit-task5-focused-final.log`. Full evidence and M3 integration notes are
  in the linked engine acceptance report. No native acceptance is claimed.
- M2 exit: complete, with grammar/directionality, typed exact ranges and empty
  inputs, dynamic membership, cycles/independent results, stack safety and
  necessary-dependent invalidation recorded in the acceptance report.
- Read plan, accepted ADRs 0016/0017 and amendments, frozen v1 source/storage
  contract and M0 evidence. Preserve current schemas, quarantine and byte fidelity.
- Native acceptance remains mandatory in M4/M5 and M6: real IME, VoiceOver,
  Find/copy/restoration and integrated layout are **not verified by M2**.
- Root orchestrator owns this record and commit/push; implementation, independent
  review and verification use separate subagents. Resolve findings and rerun
  affected checks before each task's commit. No compatibility implementation.

## Next implementation task and handoff

Use branch `tables` in `/Users/shantanugoel/.codex/worktrees/tables-m0/ganit`.
M1, M2, M3, M4 and M5 implementations are complete. Start
**M6 — Export, verification and release readiness** next.

Read this plan, accepted ADRs [0016](../adr/0016-table-semantics-and-editor-ownership.md)
and [0017](../adr/0017-table-source-and-storage.md), the frozen
[table block format](../storage/table-blocks.md),
[storage fault tolerance](../storage/fault-tolerance.md), and the
[M3 acceptance report](../design/tables/m3-integration-evidence.md).
Use `TableResultSnapshot` for result views. Use `SheetSourceCoordinator` for
source edits and document Undo. Do not save a grid projection.

The selected interface is an inline preview with Open Table. M4 adds
expanded editing and a callback for committed evaluation results. M5 must add
the inline preview, Find navigation, copy, state restoration, and the Writing
Tools policy. Real IME, VoiceOver, layout and release checks remain required in
M4, M5 and M6. M3 automated tests do not complete these checks.

The current limits are 4,000 populated cells per sheet and 1 MiB of source.
Keep metadata and manifest schema 2. Do not add support for previous schemas.
Resolve the development flag policy before merge to `main` or release.

## M3 execution record

Updated 2026-10-03. Worktree:
`/Users/shantanugoel/.codex/worktrees/tables-m0/ganit`; branch: `tables`.
Starting commit: `4087b12`. The previous execution implemented all five tasks.
It stopped before phase review, final tests, commit and push.

- Task 1: pure source transformations are implemented. They support table
  creation, row and column insertion and deletion, rename, copy, fill, move,
  duplication, and column rules. Source patches preserve persistent bindings,
  unknown fields, record order and unchanged bytes. Deleted targets remain
  broken after coordinate reuse and reload.
- Task 2: structural contract tests and storage tests are implemented. They
  cover range boundaries, locking, empty tables, rule rebasing, overrides,
  clipboard policy, TSV paste, Undo, redo, save and reload. The edit corpus
  includes 12 seeded runs of 40 edits each.
- Task 3: table calculation is integrated into the sheet evaluation pass.
  Tables capture preceding definitions and visible tables. Dividers reset
  table visibility. Table source lines have no scalar answer and separate
  aggregate blocks. Qualified prose operands read exact table values.
- Task 4: immutable table results, failure navigation and the source
  coordinator are implemented. Table formulas follow deliberate `@N` reads
  of prose through source patches. Each structural edit uses one document
  Undo step. Tests cover selection restoration, automatic save, shared window
  ownership, cancellation and clock recalculation.
- Task 5: Definitions and Quick Ganit reject table calculation. Table errors
  cannot cause assistant requests or kept answers. Titles use table names.
  Search uses display text. Table deletion writes persistent broken markers
  in dependent tables and prose.

The takeover review found and corrected three integration defects:

1. Duplicate Sheet did not call the source duplication operation. It now
   creates new table, row, column and binding IDs, preserves internal
   references, and transfers column widths to the new IDs. The original sheet
   and malformed blocks remain unchanged.
2. Table dependencies lost clock and exchange-rate provenance through
   intermediate prose variables and functions. The evaluation pass now carries
   provenance through variables, line references, aggregates and captured
   functions before it captures the table scope.
3. Table deletion did not persist fresh references without a saved binding
   ledger. Deletion now binds these references in the preceding scope and
   writes broken markers. It preserves unrelated source and ledger records.
   Tests cover Delete Table, direct block deletion, reload and name reuse.

The initial full suite passed 1,037 tests. Regression tests cover all three
review corrections. The corruption drill now checks new copy IDs and exact
preservation of the original source and malformed blocks. Frozen fixtures
remain unchanged. See the acceptance report for final verification results.

M3 exit: complete. Final verification passed 1,040 full-suite tests,
54 affected and calculator-corpus sanitizer tests, and 420 optimized table
tests. An earlier broad sanitizer run passed 427 tests. Formatting, package
validation, release app build, bundle validation, command-line checks,
document links and whitespace checks passed. The acceptance report records
the log paths. M4, M5 and M6 native acceptance remains incomplete.

## M4 execution record

Work started on 2026-10-03 on branch `tables`.

- Task 1: Add a view-based AppKit grid. The table view reuses visible cells.
  It uses system colors, table addresses and the sheet number formatter.
  Source projections contain no editable document store.

- Task 2: Add cell selection, rectangular selection, arrow and Tab navigation,
  and a native input field. Return commits. Escape cancels. Marked input does
  not change source. Committed cell edits use document Undo.

- Task 3: Add formula reference picking and range dragging. Picking keeps the
  formula draft open. Add a completion menu for range functions and current-row
  column references. Mark referenced cells with the system accent color.

- Task 4: Add column rules, override reset, row and column commands, copy,
  paste, fill and totals. Internal copy carries version 1, source identity
  and input policy. External formula paste is an explicit command. Selection
  sums and averages use typed engine values.

- Task 5: Add interpretation, full-precision copy, broken-reference repair and
  original-failure navigation. Source edits invalidate displayed results until
  the matching evaluation commits. Projection observers do not own source.

- Task 6: Add Insert Table, Open Table and Return to Sheet commands. Keep prose
  selection and scroll position. Keep table selection and scroll position when
  the table is opened again. The existing workspace keeps one editor per
  document and moves that editor between windows. Projection observers share
  that editor source and document Undo.

All six task implementations were committed in order. Phase review and native
app tests are complete. VoiceOver checks are basic, as requested by the user.
See the [M4 test report](../design/tables/m4-editor-evidence.md) for task commits,
review corrections, test results and remaining release checks.

## M5 execution record

Work started on 2026-10-04 on branch `tables`.

- Task 1: Add a mapped, read-only inline preview. Layout attributes reserve
  block space. The text storage keeps the complete source. The answer divider
  skips each preview. Basic build checks precede the task commit.

- Task 2: Add header and input type controls to Insert Table. Add the explicit
  Paste as Table command. It validates the rectangle and applies creation and
  data entry as one document edit. Ordinary paste is unchanged.

- Task 3: Show calculated values, totals, Pending and errors in the preview.
  A cell action shows its input or formula. Open Table selects that cell.
  The preview has labelled native controls and horizontal scrolling.

- Task 4: Route Find Next and Find Previous source hits to the corresponding
  expanded cell. Add source inspection. Cross-boundary copy uses native source
  selection and keeps canonical blocks. Printing shows table values and totals.
  Preview controls use natural text direction and scale with editor text.

- Task 5: Make preview blocks atomic for prose selection and edits. Structural
  commands use the source coordinator. Keep marked prose input in its current
  editor. Writing Tools is disabled on workspace sheets with tables. This
  prevents a text service from rewriting the canonical table payload.

- Phase review and native checks: commit `a9c6ab5` contains the review
  corrections and regression tests. See the
  [M5 preview test report](../design/tables/m5-preview-evidence.md) for task
  commits, review corrections, test results and native checks.

The M5 exit checks are complete. Real IME and deep VoiceOver checks remain
release gates in M6. Start M6 next.

## M6 execution record

Work started on 2026-10-04 on branch `tables`.

- Task 1: Export Table writes the open table as TSV or CSV in a values
  mode or an inputs-and-formulas mode. The CSV separator follows the
  sheet's number locale. A leading apostrophe guards fields a spreadsheet
  would run as formulas, and it does not guard numbers the locale
  displays, such as `-2,100`.
- Task 2: HTML, PDF, print and the Quick Look preview render mixed
  sheets: prose beside answers, each table as a real grid with its
  headers, values, totals and failures, and the header row repeats when a
  table continues onto a printed page. CSV export keeps one row per
  physical line, so table source stays machine-readable.
- Task 3: `ganit --tables` prints each table as a named grid at its
  block position after the line answers. Table cells never replace line
  answers. A table that cannot be read or calculated, or a cell that
  fails, exits with status 1. Services and Shortcuts keep the scalar
  contract.
- Task 4: The public table-reference grammar, recovery guidance, sample
  sheets, Help topics and release notes are written and frozen-format
  guarantees unchanged.
- Task 5: The table benchmark fixture and `--table` mode, an editor
  latency test, and task-based usability checks are complete. Benchmarks
  record honest gate status; see the evidence document.

Phase review found four defects, all fixed with regression tests: the
export guard now recognizes locale-written numbers, `--tables` rejects
line arguments, a failed table cell affects the structured exit status,
and CI runs the table benchmark. The full suite passed 1,097 tests, the
lint baseline is unchanged, sanitizer runs passed, and the app checks
covered exports, Help topics, print output and Undo. See the
[M6 release evidence](../design/tables/m6-release-evidence.md) for review
corrections, benchmark tables, the usability record and the one
intermittent undo crash that did not reproduce. VoiceOver deep review,
real IME checks, the real-participant study and the document-latency
investigation remain release activities. Publish and ship are separate
release actions.

## Table usability work — 2026-10-04

Users must be able to make and edit a table without knowledge of its source
format. Use the checklist below for this work.

- [x] U1: Add Insert Table and Paste as Table to the sheet context menu.
- [x] U2: Let the user set the row count and column count before insertion.
  Let the user set each column header and input type. Keep these settings
  when the column count changes. Show the size limits before insertion.
- [x] U3: Give the sheet preview clear row numbers, column letters, cell
  borders and a selected-cell mark. Show the full table size. Make the
  preview limit clear. Let a double-click open the cell for editing.
- [x] U4: Separate table commands from cell, row and column commands.
  Keep the table menu short. Put commands near their targets.
- [x] U5: Add context menus to cells, row numbers and column headers.
  Add rows above or below the selection. Add columns before or after the
  selection. Let the user rename a column and change its input type,
  default unit or default currency. Show the current settings.
- [x] U6: Draw a border for each visible row and column. Keep the active
  cell clear in light mode and dark mode. Keep column widths on refresh.
- [x] U7: Accept formulas in every column. Accept a function such as
  `sum(A2, B2)` during direct cell entry and add its leading `=`. Give
  useful error text at the cell. Keep external paste as data unless the
  user selects formula paste.
- [x] U8: Edit at the cell after a double-click, Return or typing. Keep
  the formula bar available. Return saves and moves down. Tab saves and
  moves right. Shift-Tab moves left. Escape cancels. A click on another
  cell saves ordinary input. Formula reference picking keeps the draft.
- [x] U9: Show the active address beside the formula bar. Explain how to
  enter a formula. Show column formulas as an optional rule, not an input
  type. Keep cell formulas independent of column rules.
- [x] U10: Add clear selected cells and Select All. Make Delete clear cell
  contents. Keep document Undo for cell edits and structural changes.
- [x] U11: Keep empty tables usable. Keep row and column insertion
  available. Show an instruction when the table has no data rows.
- [x] U12: Check creation, editing, formula entry, context commands,
  selection, Undo and refresh. Check the native view at a small window
  size. Record the checks and any remaining limits below.

Do not change the saved table format for this work. The first data row
keeps address 2 because the header is row 1. Text and Value are input
policies. A Value column can hold numbers, percentages, units and money.
A formula with a leading `=` is valid in either input policy.

### Basic spreadsheet tasks

Use these tasks to check the interface. Excel is the comparison for these
basic tasks. This work does not claim full Excel function support.

- [x] E1: Make a 5 × 4 table. Change a header and a type before insertion.
  Reduce the column count, then increase it. Keep the previous settings.
- [x] E2: Enter `1`, press Tab, enter `2`, press Tab, then enter
  `sum(A2, B2)`. The third cell must show `3`. Repeat with `=SUM(A2:B2)`.
- [x] E3: Enter `=A2+B2` in a Text column. The cell must calculate.
  A column type must not prevent formula entry.
- [x] E4: Copy a formula to the next row. Move relative references. Keep
  `$A$2`, `$A2` and `A$2` locks. Use the same rules for Fill.
- [x] E5: Paste a rectangle at the last row. Grow the table if necessary.
  Apply the paste and growth as one Undo step. Keep formula paste explicit.
- [x] E6: Use Return, Tab, Shift-Tab, arrow keys, F2, Delete and
  Command-A. A new row must be available after entry at the last row.
- [x] E7: Select a whole row or column from its header. Insert beside it.
  Keep formula targets after insertion. Restore them with Undo.
- [x] E8: Edit a cell in the sheet preview. Save with Return or Tab.
  Cancel with Escape. Open that cell in the full table.
- [x] E9: Resize a column. Edit its header or type. Keep the width.
  Show a useful cell error without requiring a separate window.

Remaining comparison areas include automatic mixed text and number entry,
Excel-specific functions, sorting, filtering, drag fill, frozen columns,
and large multi-cell editing. Record these as separate product work.

### Usability work result

The U1–U12 changes and E1–E9 checks are complete. The changes use the
existing table source format and document Undo. No new input type is
required for cell formulas. The error in direct `sum(A2, B2)` entry was
caused by its missing leading `=`. Direct function entry now adds that
character. The engine already supports the two cell arguments.

The creation form keeps settings when the user changes the column count.
The full grid and sheet preview show borders, addresses and selection.
Both views support cell editing. A small full grid fits its initial
window. User column widths survive header, type and structural edits.
An unchanged edit does not make a column-rule override or an Undo step.

Table Actions now has four table commands. Cell menus contain copy,
paste, clear, fill and cell details. Row and column menus contain their
structural commands. Column settings show the input type and default
unit or currency. An external paste or an internal range paste can grow
the table within 32 columns and 4,000 cells. Growth and paste form one
document edit. Formula paste from another app remains an explicit choice.

Native app checks used a temporary app copy with a separate test library.
The checks covered right-click insertion, a change from three columns to
four, retained headers, `1` and `2` entered with Tab, and direct
`sum(A2, B2)` entry. The result was `3`. In the sheet preview, a cell edit
changed `1` to `5`, and the formula result changed to `7`. The cell context
menu exposed row insertion, column insertion, type settings and fill.

The regression tests check relative and locked references, formulas in
Text columns, cell editing, Cancel, Tab, Shift-Tab, row growth, paste
growth, rejected formula paste, selection, column widths, empty tables
and Undo. The native views were also rendered for layout review.

The broader Excel comparison still has these limits. These are not
covered by the completed basic-entry checks:

- Text and Value remain explicit column input policies. Automatic mixed
  text and number input is not available.
- The supported Ganit functions and typed arithmetic remain in effect.
  This change does not add Excel IF, lookup or text functions.
- Multiple range arguments in one aggregate remain unsupported. Use one
  range, or a list of scalar arguments, with the supported functions.
- Sorting, filtering, drag fill and frozen columns need separate work.
- The sheet preview shows five rows and eight columns. The full table
  is the primary interface for a larger selection or reference operation.
- Deep VoiceOver and real input-method checks remain release activities.

### Verification record

- The full test suite passed 1,111 tests after the final code changes.
- The final table checks passed 51 tests. These include 14 new usability
  tests and the existing editor and workspace checks.
- The Help checks passed eight tests after the table Help text changed.
- The changed table controls passed the strict format check.
- The debug app build and bundle assembly succeeded.
- A native app check confirmed that a formula still shows `7` after its
  column input type changes to Text.
- The final native screenshots show the
  [sheet preview](../design/tables/usability-sheet.jpg) and the
  [full grid](../design/tables/usability-grid.jpg). Both show all four
  columns at the tested window size.

The changes are in the requested worktree on branch `tables`. They are
not committed or published by this work.

## End-user table and sheet review — 2026-10-04

This review checks the user tasks below. The completed U1–U12 and E1–E9
checks do not close the issues in this section. Do not treat the earlier
usability result as approval for release.

### Review method and limits

- Worktree: `/Users/shantanugoel/.codex/worktrees/tables-m0/ganit`.
- Branch: `tables`. Commit: `16d4e87f3d3fc5cfb3b3e0dfd8661b1b127cb4cf`.
- App: the debug app built on 2026-10-04 at 12:26. A copy in `/private/tmp`
  used the bundle ID `com.shantanugoel.Ganit.PersonaReview20261004`.
  This ID gave the app a separate test library.
- Input: sample data only. Stock prices were sample prices. No real account
  or investment data was used.
- Method: native mouse and keyboard actions through Computer Use. The
  checks used menus, dialogs, cell entry, paste, selection, formula fill,
  Undo, Find, view changes, app appearance and CSV export.
- Window: the initial 640 × 600 window, the same window with its sidebar
  hidden, and the window after Zoom. Dark and light appearance were checked.
- Evidence: screenshots, selected accessibility records, input sheets and
  an actual CSV export are in
  [`persona-review-2026-10-04`](../design/tables/persona-review-2026-10-04/).
  The `*-input.txt` files contain the initial stock and recipe samples.
  The `*-saved.txt` files contain the state after the checks.
- The app could not attach this worktree to this chat because another chat
  owns it. All repository reads and the report update used the requested
  worktree. The branch was already `tables`.

This is a review of the tasks performed, not a claim that all possible
issues were found. VoiceOver speech, real input methods, large-table speed,
print, PDF, file import from Excel, and recovery after a crash were not
checked. Excel, Numi, Soulver and Calca were not run for a direct comparison.
The comparison uses common spreadsheet, calculator and note tasks.

### User tasks and results

| User | Task | Table view | Sheet view |
| --- | --- | --- | --- |
| Household shopper / housewife | Enter Rice, Milk, Eggs, Soap and Tea. Enter quantity and INR price. Calculate each amount and the total. Change the milk quantity. | Entry with Tab, formula fill and the ₹522 total worked. Text input needed a type change. | Editing Milk from 3 to 4 gave the correct ₹552 total. Undo did not restore the edit. |
| Traveler | Paste six trip expenses in USD, EUR and INR. Keep a note for each expense. Total the costs. | Import worked after two columns changed to Text. Mixed-currency total failed without useful footer guidance. | The SIM expense was outside the five-row preview. The original pasted list remained below the table and showed errors. |
| Stock-market user | Review three holdings. Calculate cost, value, gain and return. Keep a decision note. Find a ticker. | Cost was $2,150, value was $2,180 and gain was $30. Find lost keyboard focus. Returns lacked a percentage display setting. | The ninth Decision column was absent. A manual return override had no visible override mark. |
| Home cook | Scale six ingredients from four servings to six, then eight. Keep preparation instructions. | Typed quantities and rule formulas worked. | Changing `servings` to 8 gave 1,000 g of flour and 500 mL of milk. Sugar was outside the preview. Instructions were shortened. |
| Freelancer | Use a $60 rate, hours, amount rules and task notes. Review a quote. Change a column formula. | The total was $810. An invalid rule was accepted and all amount cells failed. Grid Undo restored the rule. | Prose and tables could share one sheet. The rate was outside the table workspace. Long notes needed another view or a hover. |
| Student / household saver | Calculate compound savings, round a result, try IF and several range arguments, fix a divisor error and export values. | Savings gave 1,102.5. ROUND gave 3.33. IF and the range-list formula failed. External formula paste showed an internal error name. | A divisor correction calculated 0.5. Undo advanced its history but did not restore the input. CSV export kept 0.5. |

### Findings

P1 means that a common task is blocked or a user can make an unintended
change. P2 means that a task is difficult or its result is difficult to
review. P3 means a small text or presentation issue. These are proposed
product priorities. Each finding states whether it is an observed defect
or a product gap.

#### R01 — P1 — Preview Undo does not restore the cell (observed defect)

Status: Done. Preview edits use the document Undo history. The regression check restores source, results and CSV output after Tab and Escape.

Double-click B3 in the shopping preview. Change `3` to `4`, then press Tab.
Press Escape to close the next cell draft. Press Command-Z. The quantity
stays `4` and the total stays ₹552. A second Undo also left the values in
place. The menu history moved to earlier operations.

The same failure occurred on the independent Study sheet. Change B5 from
`=1 / 0` to `=1 / 2` in its preview. Press Return, Escape and Command-Z.
B5 stays `0.5`. Edit shows `Redo Edit Cell`, but the edit is still present.
Open Table also shows `0.5`. A later CSV export contains `0.5`.
Grid editing from `4` to `5`, followed by Undo, correctly restored `4`.

Required check: one Undo must restore the input, result, dependent cells
and totals in both views. The restored input must survive a view change
and export. Redo must apply the edit again.
Evidence: [preview after Undo](../design/tables/persona-review-2026-10-04/preview-undo-repro.png),
[preview record](../design/tables/persona-review-2026-10-04/preview-undo-tree.txt),
[grid record](../design/tables/persona-review-2026-10-04/grid-after-preview-undo-tree.txt).

#### R02 — P1 — Find moves focus while the user types (observed defect)

Status: Done. Incremental Find keeps keyboard focus. A match selects and
scrolls to its preview cell. Inspection gives the table name, address and
column header. Open Table opens that selected result. The menu Next and
Previous commands can also open the mapped result. The native Find field
retained all four letters of BETA without starting a cell draft. All 19
review regression tests passed after the preview result change.

Open Portfolio. Press Command-F. The app returns to the sheet and opens
Find. Type `BETA`. The Find text stops at `BET`. The last `A` starts a cell
draft in the full table. Repeat with `GAMMA`: Find stops at `GAMM`, the app
opens A4, and the last `A` starts its draft. Escape cancels that draft.

Required check: keep focus in Find until the user chooses a result. Typing
a search term must never start or change a cell draft. Give table results
their table name, address and column header.
Evidence: [Find focus failure](../design/tables/persona-review-2026-10-04/stock-find-focus.png).

#### R03 — P1 — Formula paste shows an internal error name (observed defect)

Status: Done. Formula paste gives a readable message and an explicit formula paste action.

Select Study B2. Paste two lines: `=12+3` and `=20+4`. The existing cells
are preserved. The footer shows `formulaPasteNotConfirmed`.

Required check: explain that the paste contains formulas. Offer Paste
as Formulas and Paste as Text, or name the exact command to use. Preserve
the existing cells if the user cancels.
Evidence: [paste error](../design/tables/persona-review-2026-10-04/formula-paste.png).

#### R04 — P1 — Converting selected text leaves the source list (observed defect)

Status: Done. Convert Selection to Table replaces the selected list in one document Undo step.

Paste a tab-separated trip list into a new sheet. Select it, copy it and
choose Paste as Table. The table is inserted before the selected text.
The original seven-line list remains. Those lines show calculation errors.
The sheet also shows `Incomplete`, seven selected lines and seven failures.

Required check: provide Convert Selection to Table. Replace the selected
list in one Undo step. Keep Paste as Table for insertion from the clipboard,
and make the difference clear.
Evidence: [table and remaining list](../design/tables/persona-review-2026-10-04/travel-sheet.png),
[saved trip source](../design/tables/persona-review-2026-10-04/travel-saved.txt).

#### R05 — P2 — Appearance changes leave row numbers difficult to read (observed defect)

Status: Done. The grid reloads its row views when the appearance changes.

With a dark full table open, change app appearance to Light. The grid and
text change, but row-number cell backgrounds remain dark. The dark row
numbers become difficult to read. Return to Sheet and reopen the table;
the row-number backgrounds then become light.

Required check: update all grid backgrounds and text when appearance
changes. A view change must not be necessary.
Evidence: [after Light](../design/tables/persona-review-2026-10-04/light-grid.png),
[after reopening](../design/tables/persona-review-2026-10-04/light-reopened.png).

#### R06 — P1 — Default input types reject ordinary labels (product gap)

Status: Done. Automatic input accepts labels. Strict Value and Text remain available.

All new columns default to Value. Enter `Rice` under Item. The result is
Error. Changing that column to Text restores the label. Trip import also
defaults Item and Note to Value, although their pasted data is text.

Required check: make a common label-and-number table work without type
setup. Offer automatic input detection or suitable initial text columns.
Keep an explicit strict Value choice for users who need it.
Evidence: [shopping entry](../design/tables/persona-review-2026-10-04/household-entry.png).

#### R07 — P1 — Calculator entry rules change inside tables (product gap)

Status: Done. Calculator arithmetic is normalized to a formula for value input.

Enter `85 USD * 3` in a trip cost cell. The cell fails. Show Interpretation
says `Start arithmetic input with =.` This requires a different entry habit
from the surrounding calculator note. Direct function entry can add `=`,
but this arithmetic entry does not.

Required check: support ordinary calculator arithmetic in suitable cells,
or give the correction beside the draft with one action to apply it.
Evidence: [arithmetic error details](../design/tables/persona-review-2026-10-04/travel-error-details.png).

#### R08 — P1 — Preview limits hide important data (product gap)

Status: Done. The preview contains all rows and columns in a scroll area.

The preview shows only five rows and eight columns. It hides the SIM
expense, the Sugar ingredient and the Portfolio Decision column. A general
footer explains the limit, but the user cannot inspect these cells in place.

Required check: offer Expand, Show All or a scrollable full table in the
sheet. Show an explicit count of hidden rows and columns beside the title.
A recipe or budget review must make omitted items clear.
Evidence: [recipe preview](../design/tables/persona-review-2026-10-04/recipe-sheet-updated.png),
[portfolio preview](../design/tables/persona-review-2026-10-04/stock-sheet.png).

#### R09 — P2 — The fifth preview row can be partly clipped (observed defect)

Status: Done. Preview height includes the header, visible row heights and scrollbar space.

The five-row shopping preview has a partly hidden Tea row at its lower
edge. This is a five-row table, so the preview does not show a limit message.

Required check: reserve enough height for every advertised preview row,
the header and any scrollbar. Check at both normal and Zoom window sizes.
Evidence: [shopping preview](../design/tables/persona-review-2026-10-04/household-sheet.png).

#### R10 — P2 — Preview headers lose their meaning (observed layout issue)

Status: Done. Preview headers wrap and retain their complete accessible labels.

At the initial window size, headers become `A`, `Local...`, `Ingred...`,
`Base...`, `Instru...` and `Amou...`. The cells do not retain enough context
for a quick review.

Required check: use useful minimum widths, header wrapping or a horizontal
scroll area. Keep the full header available on focus as well as on hover.
Evidence: [trip preview](../design/tables/persona-review-2026-10-04/travel-sheet.png),
[recipe preview](../design/tables/persona-review-2026-10-04/recipe-sheet-updated.png).

#### R11 — P2 — Preparation instructions and notes are shortened (product gap)

Status: Done. Text wraps in both views. Row height follows the text. Cell focus shows the input.

The recipe preview shortens `Sift before mixing` and `Warm gently`. Table
rows have one line. The full text is available in input and accessibility
help, but the user cannot read the instructions as a normal table note.

Required check: offer wrapped text and automatic row height. A focus action
must reveal the full note without entering edit mode.
Evidence: [recipe instructions](../design/tables/persona-review-2026-10-04/recipe-sheet-updated.png).

#### R12 — P2 — The initial grid clips a three-column table (observed layout issue)

Status: Done. Initial grid widths use the available pane width for a common three-column table.

Create the default three-column table in the initial 640 × 600 window.
With the sidebar shown, the third header and column are partly outside the
visible grid. Entering C2 scrolls horizontally and hides part of Item.

Required check: fit a common three-column table at the supported minimum
window size. Test with the sidebar shown and hidden.
Evidence: [shopping grid](../design/tables/persona-review-2026-10-04/household-entry.png).

#### R13 — P2 — Add controls disappear at a small width (product gap)

Status: Done. Add / Actions remains visible when the separate row and column buttons are hidden.

The initial window shows Table Actions but no + Row or + Column buttons.
The buttons appear after Zoom or after the sidebar is hidden. The commands
remain in a menu, but their location changes with available width.

Required check: keep one visible Add control at every supported width.
Explain the row and column choices in that control.

#### R14 — P2 — The formula bar is too short for common formulas (observed layout issue)

Status: Done. The formula field has a separate row and space for multiple lines.

At the initial width, a Portfolio return formula is cut off in the formula
bar. Reference and Complete use much of the same row. Review requires
horizontal cursor movement through a small field.

Required check: allow the input bar to expand or show multiple lines.
Keep the complete expression available while the user reviews references.
Evidence: [return formula bar](../design/tables/persona-review-2026-10-04/stock-override.png).

#### R15 — P1 — Narrow cells shorten money values (observed layout issue)

Status: Done. Numeric columns grow to fit calculated values.

In the Portfolio grid, cost cells show `$1,000....` at a narrow width.
A finance user must compare complete amounts, signs and decimal places.

Required check: fit or expand numeric columns. Do not shorten a money value
in a way that hides its amount. Give a clear overflow display if it cannot fit.
Evidence: [portfolio amounts](../design/tables/persona-review-2026-10-04/stock-override.png).

#### R16 — P2 — A wide preview spreads related values too far apart (product gap)

Status: Done. Preview columns use preferred widths in the horizontal scroll area.

After Zoom on the review display, the four shopping columns fill the width
of the sheet. Item labels and their quantities are far apart.

Required check: provide readable preferred widths for previews. Allow users
to expand them when needed. Do not use all available width by default.
Evidence: [wide shopping preview](../design/tables/persona-review-2026-10-04/household-sheet.png).

#### R17 — P2 — Text selection reports a zero sum (observed presentation issue)

Status: Done. Selection status reports value, text and blank counts. A text-only or blank-only selection has no aggregate.

Select a text cell such as Savings, Rice or a ticker. The footer shows
`Sum: 0`. Empty-cell selections also show a zero sum. This suggests that
a numeric calculation was performed on the selection.

Required check: show the numeric count before an aggregate. Omit Sum and
Average when no numeric values are selected. Distinguish text from blanks.
Evidence: [text selection](../design/tables/persona-review-2026-10-04/light-grid.png).

#### R18 — P3 — Selection count has incorrect singular text (observed text issue)

Status: Done. Selection status uses cell for one cell and cells for other counts.

A one-cell selection shows `1 cells`.

Required check: show `1 cell` and use the correct plural for other counts.

#### R19 — P2 — A selected range is not named (product gap)

Status: Done. Selection status shows the range, dimensions and source cell.

A selected amount column reports five cells, Sum and Average. The input
bar shows only its active cell address. It does not show `D2:D6`.

Required check: show the selected range and dimensions. Make it clear which
cell supplies a fill or a paste operation.

#### R20 — P2 — Fill collapses the review selection (observed behavior)

Status: Done. Fill retains the range and updates its aggregate.

Select D2:D6 in Groceries and use Command-D. The formulas move correctly.
After the fill, the summary describes only D6 and its ₹150 value. The user
must select the range again to check the ₹522 total.

Required check: preserve the filled range and its aggregate after Fill.
Keep the source cell and active cell clear.

#### R21 — P2 — Totals are separate from their columns (product gap)

Status: Done. The expanded grid has a total row under its columns. Selection status is separate.

Full-table totals appear in a text strip below the grid. They do not sit
under Cost, Value and Gain. The strip also shares the lower area with a
selection summary. In a wide table, it is difficult to match each total
to its column and distinguish it from a selected-cell result.

Required check: align a total row with the columns. Keep table totals and
selection aggregates visually distinct.
Evidence: [portfolio footer](../design/tables/persona-review-2026-10-04/stock-override.png).

#### R22 — P1 — A mixed-currency total has no recovery path (product gap)

Status: Done. Mixed-currency sums show a separate total for each currency.

Total the trip Local cost column. Its cells contain USD, EUR and INR.
The footer shows `Local cost sum: Error`. The sheet preview shows the same
text. Selecting one cost gives its normal value, but does not explain how
to repair the total.

Required check: explain the incompatible currencies. Offer totals by
currency or an explicit conversion currency. If conversion is used, show
the rate date and source, and permit a user-supplied rate.
Evidence: [trip total](../design/tables/persona-review-2026-10-04/travel-total.png).

#### R23 — P1 — Unsupported formulas have a generic diagnostic (observed defect)

Status: Done. Formula diagnostics name unsupported functions and argument patterns. Editing selects the problem range.

Study B3 contains `=IF(B2 > 1000, 1, 0)`. Its result is Error.
Show Interpretation says only `Check the formula and its references.`
The user cannot tell whether IF, the comparison or a reference is invalid.

Required check: name the unsupported part. Mark it in the draft and give a
supported example when one exists. Do not suggest a broken reference when
the feature is unsupported.
Evidence: [IF diagnostic](../design/tables/persona-review-2026-10-04/if-details.png).

#### R24 — P1 — Common spreadsheet decisions and range lists are blocked (product gap)

Status: Done. A native repeat check found that a failed range member could
hide the unsupported multiple-range pattern. The engine now reports that
formula problem first and selects its first range in the draft. The check
also verifies the exported error text. All 19 review regression tests and
384 engine table tests passed. The native Find test failed in the combined
run and passed when run alone.

Help states the supported function scope. Completion lists supported functions. Multiple range arguments have a specific diagnostic. Decision functions remain outside this release.

The IF example and `=SUM(B2:B3, B5:B6)` fail. These are common spreadsheet
entry patterns. `=ROUND(10 / 3, 2)` works and gives 3.33. Function support
is therefore difficult to predict from a familiar name alone.

Required check: decide the basic spreadsheet function scope. Publish it in
app Help and completion. Give a specific diagnostic for unsupported range
argument patterns. Add decision functions if they are in that scope.

#### R25 — P1 — Calculated returns lack a percentage display (product gap)

Status: Done. Percentage display and decimal places are stored separately from input and formulas.

Portfolio Return uses `=([@Now price] / [@Buy price] - 1) * 100%`.
Its results are `0.1`, `-0.1` and `0.2`. Entering a literal `10%` displays
`10%`. Column Settings offers input type, unit and currency, but no
percentage display choice.

Required check: offer a percentage format independent of the formula and
input policy. Show 10%, -10% and 20% for this ratio example. Preserve the
stored numeric value and support a chosen number of decimal places.
Evidence: [column settings](../design/tables/persona-review-2026-10-04/stock-settings.png),
[literal and calculated returns](../design/tables/persona-review-2026-10-04/stock-override.png).

#### R26 — P1 — The preview hides a manual rule override (observed presentation issue)

Status: Done. Both views show the override mark. Preview inspection states
the column formula and cell input. Restore Column Formula removes the
override in one document edit. The regression check verifies restoration
and Undo. All 16 table review regression tests passed.

Replace Portfolio H2 with the literal `10%`. The grid shows `10% •`.
Return to Sheet. The preview shows `10%`, with no dot. Its help shows the
literal, but does not say that it overrides the column rule.

Required check: show the same override state in both views. On focus,
explain the column rule, the cell input and the action to restore the rule.

#### R27 — P2 — The column formula dialog gives no syntax help (product gap)

Status: Done. The column rule form gives a current-row example, references, note definitions and a sample result.

Set Column Formula opens one small text field and Apply/Cancel buttons.
There is no example, completion, reference picker or sample result. A user
who enters `=Hours * rate` gets failures in every amount cell.

Required check: show a current-row example such as `=[@Hours] * rate`.
Offer available column names and definitions, and show a sample row result.
Evidence: [formula dialog](../design/tables/persona-review-2026-10-04/column-rule.png).

#### R28 — P2 — Apply accepts a failing column rule without a preview (product gap)

Status: Done. The column rule form checks the draft and disables Apply if the rule fails.

Applying `=Hours * rate` closes the dialog and changes every Amount cell
to Error. The grid then reports that the identifier is not defined.
Grid Undo correctly restores the original rule and $810 total.

Required check: check the rule before Apply. Keep the dialog open with a
specific problem and a correction. Permit an explicit incomplete draft
only if that is a planned workflow.
Evidence: [failed quote rule](../design/tables/persona-review-2026-10-04/rule-error.png).

#### R29 — P2 — Complete opens an entirely disabled menu (observed UI issue)

Status: Done. Complete starts a cell draft before it offers insertions.

With a rule cell selected but no edit in progress, click Complete.
The menu contains functions and current-row references, all disabled.
The Complete button itself was enabled.

Required check: start an appropriate draft when Complete is used, or disable
the button and explain how to edit first. Do not open an unusable menu.

#### R30 — P2 — Formula suggestions omit note definitions (product gap)

Status: Done. Completion offers visible note definitions with their values.

The Quote completion menu lists six aggregate functions and the current-row
columns. It does not offer the preceding definition `rate`. The recipe also
uses preceding definitions `servings` and `base`.

Required check: offer valid note definitions with their current values.
Distinguish a row reference from a note definition. The table must remain
a useful part of the calculator note.

#### R31 — P1 — Table review lacks sort and filter (product gap)

Status: Done. Stable view sort and text filters keep canonical row identities. Source storage records review state for Undo and reload. Both views show filter state.

Clicking the Portfolio Gain header did not reorder rows. Table Actions and
the column menus offer no sort or filter commands. A stock user cannot put
losses first. A traveler cannot show only one currency or category.

Required check: support a stable sort and simple filters. Preserve formula
targets, row identity and Undo. Make an active filter and hidden-row count
visible in both views. These controls are basic review needs, not a request
for all Excel features.

#### R32 — P1 — Horizontal review loses row identity (product gap)

Status: Done. The expanded grid can freeze one column and shows the selected row label.

Scroll to Portfolio Gain, Return and Decision. Ticker is outside the visible
area. The user must remember which holding each row represents.

Required check: offer a frozen label column. Keep row numbers and headers
visible while scrolling. Show a selected row label near the input bar.
Evidence: [portfolio horizontal review](../design/tables/persona-review-2026-10-04/stock-override.png).

#### R33 — P2 — Export does not expose its file format choice (product gap)

Status: Done. Export has a CSV or TSV selector, extension and locale delimiter text.

Export Table shows Values or Inputs and Formulas and Include header row.
There is no visible CSV/TSV selector in the compact save dialog. The user
must supply an extension to choose the separator. Saving a `.csv` file
worked. Source inspection confirms that `.csv` selects CSV and other
extensions select TSV.

Required check: show a file format selector and matching extension.
Describe the delimiter for the current number locale.
Evidence: [export dialog](../design/tables/persona-review-2026-10-04/export.png).

#### R34 — P2 — Export loses some error explanations (observed presentation issue)

Status: Done. Copy Values and values export use complete cell diagnostics. Export shows an error count and offers an error report.

The actual Study CSV writes `These quantities have incompatible dimensions.`
for Wrong units. It writes only `Error` for Decision and Range list.
A recipient cannot identify the unsupported formula from those values.

Required check: use a consistent error policy for Copy Values and export.
Offer an error report with table name, address, input and problem. Make any
remaining errors clear before the file is saved.
Evidence: [actual CSV](../design/tables/persona-review-2026-10-04/study-values.csv).

#### R35 — P2 — Table setup is absent from the first-use tour (product gap)

Status: Done. The tour has a table step and a creation action. The creation form offers Shopping, Travel, Quote and Portfolio starters.

The four tour steps cover calculation lines, named values, Quick Ganit and
Help. They do not introduce table creation, text columns, formula entry or
the difference between Open Table and the sheet preview.

Required check: add a short table example and a visible creation action.
Offer starter tables for shopping, travel, a quote and a portfolio.

#### R36 — P2 — Accessibility exposes the stored table block (observed accessibility issue)

Status: Implementation complete; VoiceOver speech check open. Accessible
text replaces the stored table block with its name, row count and headers.
Both the modern and legacy selected-text APIs use that text. Cell selection
follows visible row identities after sort and filter. Both views include
the complete problem in each failed cell label. All 18 table review
regression tests passed. The speech check requires permission to enable
VoiceOver temporarily. Do not mark this issue Done before that check.

The sheet text entry area exposes the complete `@ganit-table` block,
including its JSON and IDs. Its preview also exposes readable cell buttons.
The full grid accessibility record marks every cell in an active row as
selected, although the visible selection is one cell.

Required check: expose the note and table as meaningful document elements.
Expose the actual cell selection and complete error text. Verify this with
VoiceOver speech before closing the issue. This review checked the
accessibility records, not VoiceOver speech.
Evidence: [preview record](../design/tables/persona-review-2026-10-04/preview-undo-tree.txt),
[grid record](../design/tables/persona-review-2026-10-04/grid-after-preview-undo-tree.txt).

#### R37 — P2 — Table view updates in sheets and table view

Status: Done. The preview width follows the sheet input area. Both table
views keep a horizontal scrollbar visible. The grid draws each row
separator once. Its frozen column uses the same spacing and grid settings.
All 17 table review regression tests passed. Native checks at 640 × 600
confirmed the input boundary, visible scrollbar and aligned row separators.
Evidence: [sheet](../design/tables/persona-review-2026-10-04/r37-sheet.png),
[grid](../design/tables/persona-review-2026-10-04/r37-grid.png).

- In sheets view, the table spans and takes over the results area as well which is jarring, it should remain within the input area
- In sheets view, when the table is wider than the port, the scrollbar appears only when you have a mouse that can scroll horizontally, we should allow easy way to scroll (either with or without scrollbar)
- In table view, the cell row borders are weird, unaligned and many places double bordered, while in sheets view it is fine

### Work order and completion checks

1. Fix R01 and R02 first. Test edit, Cancel, Undo, Redo and Find across both
   views. Include a view change and an actual export in the Undo check.
2. Fix R03–R05. Replace internal messages, define selection conversion and
   update appearance without reopening the table.
3. Remove the common entry and review blocks. Start with label input,
   arithmetic entry, full previews, money widths and percentage formatting.
4. Add sort, filter and a frozen label column. Keep reference identity and
   document Undo intact. Do not implement these as changes to visible text
   alone.
5. Improve formula help, rule validation, total diagnostics and export.
   Use the same source, result and error model in both views.
6. Repeat the six user tasks above in a fresh test library. Use a small
   window, hidden sidebar, wide window and both appearances. Ask users who
   use spreadsheets and note calculators to complete the tasks without
   reading the implementation plan.

The repeat check must let a new user create and finish a shopping budget,
change a trip expense, review a stock loss, scale a complete recipe, adjust
a quote and repair a failed calculation. The user must be able to see the
full inputs, results, hidden-data state and errors. One Undo must restore
any committed cell edit. A search must never start an edit. Successful
arithmetic alone is not sufficient to close this review.

### Review change and verification record

The original review added findings and evidence files. Its native checks
and actual CSV export remain the evidence for the reported failures.

The existing implementation changes were checked on 2026-10-04 before
commit. All 15 `TableReviewRegressionTests` passed. The completed findings
above describe those changes. R36 remains open for further work.
R36 requires a VoiceOver speech check before it can be closed.

The full suite passed 1,126 tests before the R26 follow-up change.

Format check: Done. The preview cleanup uses a for-in loop. This removes
the strict format error in the existing changes.
