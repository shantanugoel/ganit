# Tables in Ganit: product and implementation investigation

Date: 2026-10-01. Status: proposal, not an accepted ADR or implemented feature.

Follow-up: the [reviewed implementation plan](../plans/tables-implementation.md)
defines milestone order, acceptance gates and more precise semantics. Its
explicit decisions refine this investigation's open questions. The
[saved visual references](tables/README.md) include both layouts and a portable
interactive concept.

## Recommendation

Make a **named, bounded calculation table a block in any ordinary or Markdown
sheet**, with an expanded table editor for concentrated work. A table-only
starting template can create a sheet containing one table; it does not need a
different document type, formula engine, or file format.

The useful workflow is assumptions → table → explanation/conclusion. For
example, a party budget can declare `people = 20`, contain an `Items` table,
then calculate `sum(Items[Amount]) / people` below it. Several tables can live
in one sheet. Tables should carry Ganit's units, money, exact arithmetic and
explainable failures into repeated calculations.

This follows the existing product principles of composition, a simple first
frame and recoverable source. It is technically feasible, but it is a
substantial language and editor extension, not just drawing a grid.

## What exists today

These findings come from the current source, not just the original plan:

| Area | Existing behavior | Implication |
| --- | --- | --- |
| Sheet modes | Markdown is `DisplayOptions.writesAnswersInline`, passed into evaluation; there is no separate Markdown document class | Tables can be independent of presentation mode |
| Evaluation | `SheetCalculator` folds lines top to bottom; `LineOutcomes` contains only earlier results | Arbitrary cell dependencies need a separate graph scheduler |
| Arithmetic | Typed exact numbers, percentages, quantities, rates, money, dates and times | Reuse arithmetic and formatting rather than introducing a floating-point spreadsheet engine |
| References | `line N`, `@N`, `previous`, block aggregates; automatic source rewrites preserve references through edits | Reuse the reference-integrity principles, but line IDs cannot serve as durable table cell IDs |
| Grammar | No cell/range AST, square-bracket references, strings, booleans, comparisons or `if` | Addressing and conditional/lookup functions are real language work |
| Editor | One plain `NSTextView` source, one document undo manager, TextKit decorations and answer overlays | An interactive table projection needs source mapping, focus, selection and undo integration |
| Storage/export | UTF-8 canonical source; versioned JSON metadata and `.ganit` manifest; exports currently model lines and answers | Tables need recoverable source and block-aware export, not only metadata |

Source anchors:

- [SheetCalculator](../../Sources/GanitEngine/SheetCalculator.swift),
  [LineOutcomes](../../Sources/GanitEngine/LineOutcomes.swift),
  [Expression](../../Sources/GanitEngine/Expression.swift),
  [EngineValue](../../Sources/GanitEngine/EngineValue.swift).
- [Parser](../../Sources/GanitEngine/Parser.swift),
  [Evaluator](../../Sources/GanitEngine/Evaluator.swift),
  [EvaluationLimits](../../Sources/GanitEngine/EvaluationLimits.swift).
- [SheetEditorViewController](../../Sources/GanitEditorUI/SheetEditorViewController.swift),
  [SheetTextView](../../Sources/GanitEditorUI/SheetTextView.swift),
  [SheetEvaluationScheduler](../../Sources/GanitEditorUI/SheetEvaluationScheduler.swift).
- [SheetStore](../../Sources/GanitDocuments/SheetStore.swift),
  [SheetExchange](../../Sources/GanitDocuments/SheetExchange.swift),
  [SheetDocumentRenderer](../../Sources/GanitEditorUI/SheetDocumentRenderer.swift),
  [DisplayOptions](../../Sources/GanitFormatting/DisplayOptions.swift).
- [Product feature checklist](../../PLAN.md#13-feature-entry-checklist),
  [reference-integrity decision](../adr/0015-reference-integrity-and-release-notes.md),
  [frozen formats](../reference/schema-freeze.md).

Read-only probes using the existing debug CLI and engine harness corroborated
the source review: `sum(2, 3, 4)` → `9`, `sum(2 USD, 3 USD)` → `5 USD`, and
`sum(1 kg, 500 g)` → `3/2 kg` at full precision. A downward `line N` fails;
cell ranges, structured references, `$B$2`, leading `=`, quoted strings and
`if` are unsupported. Crucially, `B2 = 7` followed by `B2 * 3` already works as
an ordinary variable declaration/reference. These were existing binaries,
not a fresh build or a test of a table implementation.

## Sheet type versus embedded table

| Option | Strength | Cost / weakness | Decision |
| --- | --- | --- | --- |
| Dedicated spreadsheet sheet | Full-width grid; easier initial editor integration | Separate workflow, assumptions stranded outside the grid, duplicate sheet behavior | Useful as a later template/view, not the underlying model |
| Editable table block | Context, assumptions, tables and results stay together; works in either mode | Harder TextKit and selection integration | Recommended document model |
| Pipe table treated as aligned text | Easy initial source and CLI support | Poor cell selection, paste, fill, navigation and reference picking | Useful source representation/prototype, insufficient final UX |

A dedicated sheet does not solve the difficult calculation/reference problems.
It only simplifies the first UI surface. Therefore an implementation spike can
start with the expanded editor while keeping its underlying table a document
block, then add in-place editing when native text behavior is proven.

## Proposed user experience

1. **Create where you are.** Insert Table at the cursor, or offer Create Table
   when pasting a rectangular tab-separated selection. Avoid turning every
   multi-line paste into a table. Permit a table-first new-sheet template.
2. **Start small.** A named table with meaningful headers, a few rows and an
   add-row action. Quiet dividers, right-aligned numbers, system typography,
   Ganit number formatting. Show addresses on focus/formula editing rather
   than making spreadsheet chrome permanent.
3. **Edit cells directly.** Arrows navigate; Tab/Shift-Tab move between cells;
   Return commits and advances; Escape cancels. When editing a formula,
   clicking or dragging cells inserts references rather than moving the
   editor. Explicit controls distinguish editing from reference picking.
4. **Write a column formula once.** A header action sets `Amount` to
   `=[@Qty] * [@[Unit price]]`. Added rows inherit it. Individual exceptions
   are visibly marked and can be reset to the column formula. Typing in one
   cell does not silently overwrite a whole column.
5. **Make the calculation inspectable.** Display the result normally; show
   the source and referenced cells when selected. Reuse Show Interpretation,
   full-precision copy, units, rounding and currency provenance. Formula
   cells have an accessible formula indication, not only a color.
6. **Summarize without writing.** Rectangular selection shows a count and,
   where types permit, total and average. Include a deliberate totals row
   whose aggregates exclude itself.
7. **Expand when useful.** The same table can occupy the editor pane, with
   stable headers and a compact formula field. Return to Sheet restores the
   cursor and scroll position. Table changes and prose changes share Undo.
8. **Support real transfer.** Paste and copy rectangular TSV; offer copy
   values versus copy formulas. CSV import has header/type/locale review.
   Formula paste is identified explicitly; literal leading `=` can be kept
   as text. Do not imply that an Excel clipboard guarantees formula fidelity.

The interaction mockup accompanying this proposal demonstrates input changes,
row addition, a fixed calculated-column rule, and dependent sheet results.
It is a product concept; it does not execute the Ganit engine or implement an
arbitrary formula parser.

Concept verification: changed Drinks quantity from 20 to 10 and observed the
total move from INR 9,200 to INR 8,000 and cost per person from INR 460 to
INR 400; adding a row at INR 100 produced INR 8,100 / INR 405. Confirmed the
new row inherited the displayed formula, the expanded view retained the same
inputs, invalid inputs were identified, and layouts fit 320, 360 and 736 px
without outer horizontal overflow. The table itself scrolls horizontally at
narrow widths. No browser warnings/errors were observed during these checks.

## Formula and reference contract

The following forms are **proposed syntax**, not working Ganit syntax. Use
familiar A1 references for spatial work and structured references for readable,
growing tables. Excel itself documents named column references and calculated
columns; these are a useful precedent, not a reason to copy its whole UI.
[Microsoft: structured references](https://support.microsoft.com/en-us/excel/using-structured-references-with-excel-tables).

| Need | Proposed form | Meaning |
| --- | --- | --- |
| Individual cells | `=B2 * C2` | Formula within the current table |
| Fixed or partly fixed reference | `=$B$2 * C2`, `=$B2`, `=B$2` | Row/column locking when copying or filling |
| Rectangular range | `=sum(B2:D6)` | Aggregate compatible values in a rectangle |
| Whole column | `=sum(C:C)` | Populated data cells in column C, excluding header and totals |
| Whole row | `=sum(2:2)` | Data cells across row 2; must be type-compatible and must not include the formula itself |
| Current row, named columns | `=[@Qty] * [@[Unit price]]` | One scalar from each named column on this row |
| Whole named column | `=sum(Items[Amount])` | Data rows only; grows with the table |
| Another table's cell/range | `=Rates!B2`, `=sum(Items!D2:D8)` | Qualified reference to an earlier table in the same sheet |
| Earlier sheet variable | `=[@Qty] * people` | Scope visible at the table's position |
| Table result in ordinary prose calculation | `cost = sum(Items[Amount])` | Ordinary Ganit line below the table; no leading `=` required |

Keep the conventional header at row 1, with the first data row numbered 2.
Local addresses and named-column references are two ways to target the same
cells. Table identifiers are unique within visible sheet scope; column names
are unique within their table. Headers can contain spaces and unit words
because brackets explicitly name columns. Define escaping for brackets and
punctuation. A table boundary does not reset ordinary variable scope; a divider
retains its current reset semantics. Moving a table across a variable
declaration can change its inherited scope and needs clear feedback.

The `$` rules should follow familiar relative/absolute/mixed behavior on
copy/fill. Inserting rows or columns still follows the target; `$` does not
freeze a coordinate through structural changes.
[Microsoft: reference locking](https://support.microsoft.com/en-au/excel/switch-between-relative-absolute-and-mixed-references).

### Compatibility and ambiguity

- Bare `B2` remains an ordinary variable outside tables. Table formulas get
  an explicit parsing context in which A1 addresses are recognized. Provide
  an explicit sheet-variable qualifier for any inherited name that resembles
  an address; its exact spelling is a grammar-spike decision.
- Preserve `@2` as a sheet-line reference. `[@Qty]` has distinct brackets;
  do not overload bare `@Qty` or change existing completion semantics.
- `$` currently introduces money, `!` is factorial, and `:` appears in labels
  and times. New references need context-aware tokenization/binding, with
  regression cases for all three, rather than global regular-expression
  replacement. Uppercase Excel function aliases should be scoped and explicit.
- A leading `=` distinguishes a formula cell from text/literal input. The
  cell editor can offer Calculate for a selected expression; do not guess
  whether a label such as `May`, `USD`, or `1-2` should calculate.
- Within table formulas, require explicit range arguments for aggregates.
  Bare `sum`, `subtotal` and `previous` must not accidentally read all prior
  sheet lines. Either diagnose them or document a specific table meaning.

### Correctness on editing

Persist stable table, row and column identities. Bind references to identities
and retain the relative/absolute copy flags, then rewrite readable addresses
through structural edits as one undoable operation. Rename operations rewrite
named references; deletion leaves a persistent broken reference that cannot
rebind merely because another row takes the old position.

For scalar references, sorting/reordering follows the referenced record and
rewrites displayed addresses. Rectangular ranges retain a documented rectangle
policy; sorting must not silently turn them into an arbitrary scattered set.
Choose and test that policy before enabling destructive sort. A view-only sort
can initially avoid changing canonical order. Whole-column named references
always target the column's current data membership. Filtering is a view change;
ordinary sums include hidden rows, with visible-row totals offered separately.
Formula fill and move are different operations: fill translates unlocked
addresses; move preserves targets. Copying a whole table mints new IDs and
rebases internal references to the new table.

Never substitute formatted answer text into formulas: that loses precision,
units and dependency identity. Do not treat missing references or failed cells
as zero. `sum`/`average` can skip blank and text cells in a range with a documented
policy, but propagate failed formulas and reject incompatible value kinds;
scalar arithmetic on blank/text is an error. Define numeric `count`, nonblank
count and selection count separately. Mixed currencies require an explicit
conversion. Whole-row/column references that include their own formula are
cycles. No implicit Excel-style coercion or iterative circular calculation.

## Calculation architecture

Introduce block recognition before line classification, using exact source
ranges and existing physical line numbering. A table is one semantic block
with physical source lines, not a collection of ordinary calculation lines.

For the first version preserve top-to-bottom sheet semantics:

```text
Earlier ordinary lines and definitions
                  ↓ captured scope
Table block: cells/ranges → dependency graph → typed results
                  ↓ named table resolver
Later ordinary lines and later table blocks
```

Cells within one table can refer left/right/up/down. The table's graph orders
evaluation and detects cycles. A table can read earlier tables and ordinary
declarations, and later lines can read its outputs. It cannot read a later
sheet line or later table in this initial design. That restriction preserves
redeclared variables, dividers and existing scope. Arbitrary table-to-table or
cross-sheet forward references would be a separate document-graph feature.

Suggested responsibilities (new names are illustrative):

- `DocumentBlocks` recognizes source spans; `TableSource` records headers,
  cells, column rules, identities and source ranges. Keep table source as
  source, not a second independent editable representation.
- `FormulaReference` adds cell, rectangle, entire-row/column, current-row and
  named-column operands to the AST. A resolver binds them to targets.
- `TableCalculator` builds dependency edges and reverse edges, identifies
  strongly connected components and evaluates the remaining graph in order.
  Diagnose every cycle participant and mark its downstream cells blocked;
  unrelated cells should still calculate.
- A reference-binding pass can discover graph edges before full type-directed
  parsing. This matters because Ganit parses percentage and unit phrases using
  the visible operand kinds. Once dependencies are ready, parse/evaluate with
  those kinds and retain source ranges; do not assume every cell is a number.
- Reuse `Evaluator` and its arithmetic through a typed reference resolver.
  Add a cell/operand layer for blank, text, scalar values, ranges and errors;
  ranges should be views over cell outcomes, not thousands of synthesized
  positional function arguments. Existing min/max numeric paths also need
  auditing before promising typed range versions.
- Invalidate changed cells and their transitive dependents. Range dependencies
  also track membership, so added/deleted rows update whole-column aggregates.
  Avoid expanding every whole-column dependency into a huge repeated edge list.
  Apply graph, cell-count, range-work and arithmetic budgets and cancellation.
- Reuse immutable evaluation generations and latest-only UI commits, including
  clock/rate context. Preserve provenance transitively through cell references.
  Table rows should not automatically participate in ordinary bare `sum` or
  `previous`: readers explicitly request table results to avoid double counts.

## Native editor implementation

Use an AppKit table controller for the grid. A view-based `NSTableView` provides
row/cell reuse and native cell editing, but rectangular cell selection,
spreadsheet keyboard behavior, formula reference picking and fill still need
explicit implementation. It is not a turnkey spreadsheet.
[Apple: table view behavior and reuse](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TableView/TableViewOverview/TableViewOverview.html).

Start by projecting a selected source block into an expanded table editor.
All grid commands must update the document source through the same undoable
edit path. Keep one authoritative source store; refactoring its ownership out
of the text-view controller may be necessary. Preserve the existing plain-text
path for sheets without tables.

Then prove a table renderer embedded in the sheet. TextKit block layout or a
source-mapped projection can reserve the table span and host the grid. Do not
replace canonical source with attachment/object-replacement characters or
maintain an unsynchronized hidden text editor. Focus, Find, copy across the
table boundary, IME, accessibility and source offsets are feasibility gates.
If the in-place editing spike fails these gates, ship an inline preview with
Open Table editing first; retain the same underlying block.

Use the existing semantic colors, system fonts and result formatting. Retain
source/code inspection as an escape hatch. Do not introduce a web spreadsheet
runtime just to get a grid: that would require another language/numeric engine,
bridge, accessibility model and footprint assessment.

## Persistence and export

Keep a self-contained, readable **versioned table block in canonical UTF-8
source**, available in both presentation modes. Use an explicitly marked block
rather than treating all Markdown pipe tables as calculations. It must contain
cell input/formulas, column formulas, durable table/row/column IDs and broken
references. The UI can hide identity metadata; source export must keep it.

The precise text grammar is unresolved: prototype a fenced or directive block
with a readable grid and identity records. It needs quoting/escaping for pipes,
newlines, brackets, Unicode, locale separators and formulas using bitwise `|`.
Do not commit a pretty example as a format before those round-trip cases work.
Plain Markdown export can omit IDs and show values; it is a presentation
export, not the lossless document source.

Presentation-only column widths and expanded-view state can be metadata. Cell
identities/formulas must not live only there: plain-source recovery and export
would otherwise silently lose them. Derived answers remain out of the canonical
manifest/source. Malformed blocks retain their exact text and get diagnostics.

Record required table syntax support in a new compatible document/metadata
schema with a migration ADR, fixtures and frozen-format updates. A table block
version alone cannot make older binaries fail safely; unknown-version handling
in `.ganit` manifests and library metadata must be tested. Existing legacy
sheets continue loading. Raw text imported into older Ganit can still be
misinterpreted, so a newer reader's gating cannot guarantee that path.

Update block-aware CSV/TSV, HTML, PDF/print and Quick Look rendering. One-table
CSV exports values, with an explicit formulas option; a whole mixed sheet
needs table selection or separate exports, not an accidental flattened grid.
Headless/CLI calculation should use the same block evaluator, with a documented
table-result output format. Search, duplication, autosave, backups, trash and
recovery must preserve the same source without a new storage subsystem.

## Suggested delivery sequence

1. **Feasibility spikes.** Prove source round-tripping with durable identities;
   arbitrary intra-table dependencies and cycles; expanded grid editing through
   document Undo; and a native inline projection with Find, IME and VoiceOver.
   These determine scope more reliably than a calendar estimate.
2. **First useful release.** Named table blocks in both modes; text/literal
   inputs and formula cells; A1, mixed/absolute locks, rectangles, whole
   rows/columns and structured references; calculated columns; aggregates and
   existing arithmetic; sheet-variable input and downstream sheet use; add/
   delete, rectangular copy/paste/fill, visible errors and focused editing.
   Ship in-place editing only if its gates pass. This is a substantial feature.
3. **Decision and lookup utility.** Comparisons, booleans and lazy `if`,
   `sumif`/`countif`, then exact-match lookup, text operations, sort/filter and
   explicit visible-row totals. These depend on additional value types and
   semantics, not just new function names. Prioritize after observing real jobs.
4. **Only with demand.** Cross-sheet references, arbitrary cross-block forward
   graphs, dynamic-array spills, charts and `.xlsx` import/export. Excel file
   fidelity, its large function library, macros and pivot tables are separate
   commitments and are not implied by spreadsheet-style calculation.

The first two spikes should be small and disposable. Do not promise a release
date until both the engine and native editor prototypes have been measured.

## Acceptance and research gates

- Preserve existing sheet answers and variable names, including `B2`, money
  `$`, factorial `!`, time/label `:`, `@N`, definitions and Markdown paragraphs.
- Exercise forward cell refs, chains, independent components, cycles,
  propagated failures, exact values, compatible/incompatible units and money.
- Specify and verify blank/text/error aggregation, range growth, totals
  exclusion, row/column locking, fill versus move, deletion, renaming,
  duplication, reordering and reload. An added row must update named aggregates.
- Cover source → model → source fidelity; malformed/unsupported blocks;
  old/new document versions; autosave interruption, backup recovery and exports.
- Check cell selection, multi-cell paste, formula reference picking,
  column-formula exceptions, shared Undo, native editing/IME and VoiceOver.
- Benchmark populated-cell workloads rather than an infinite empty grid:
  1,000 ordinary cells and a 10,000-cell dependency stress case, including
  whole-column membership edits. Use the existing 16 ms / 50 ms P95 edit-to-
  answer goals as provisional targets, not measured table claims. Verify idle
  CPU and memory and regressions in table-free sheets/Quick Ganit.
- Compare 5–8 representative users doing three real tasks: budget plus per-
  person cost, unit-aware material estimate, and recurring monthly figures.
  Observe creation, reference picking, a new row, a formula error and return
  to prose; assess discoverability and task completion, not preference alone.

**Decision:** proceed with table blocks plus an expanded view as the product
direction, gated by small engine and native-editor spikes. A new sheet type is
not required; full Excel compatibility is neither present nor necessary to
deliver the core utility.
