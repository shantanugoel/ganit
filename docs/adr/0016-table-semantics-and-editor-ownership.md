# ADR 0016: Calculation table semantics and editor ownership

- Status: Accepted (architectural direction; production acceptance is M4–M6)
- Date: 2026-10-01
- Scope: Architecture for M1–M6, not shipping table support

## Decision

Use explicit bounded table blocks within an ordinary or Markdown sheet, with
one live top-to-bottom scope. Capture variables, units, custom functions,
rates and clock context at each table's entry. Tables end ordinary aggregate
blocks on both sides without clearing variables. Dividers clear visibility;
table names remain case-insensitively unique sheet-wide. Definitions rejects
tables and Quick Ganit diagnoses them with a workspace path. No automatic
assistant calls for a table or its errors.

Keep scalar arithmetic in `GanitEngine` and `EngineValue`. Blank/text/ranges
and failures belong to a distinct operand layer. Discover and bind references
before value-kind-directed parsing. Within a table use iterative SCC discovery,
then dependency-order evaluation, retaining reverse dependencies and shared
range-membership nodes. Cycle participants and their blocked readers have
separate outcomes; independent components still calculate. Typed aggregate,
empty/count and provenance rules are those in the implementation plan.

The [M0 spike](../../Spikes/TablesM0/README.md) proves a two-pass iterative SCC
walk, forward references, exact decimal addition through Ganit's existing
`Evaluator`, and a stack-safe 10,000-node chain. It is not a formula parser or
an incremental table evaluator. Range caching, operation budgets, cancellation
latency and typed min/max still require M2 proof.

## Reference grammar

References are recognized by a dedicated token pass at operand positions.
Never search arbitrary formula strings with a global A1 regular expression.
Within table formulas, bare A1 references take precedence over inherited
variable names. Outside tables bare `B2` remains an ordinary variable.

- ASCII column letters, case-insensitive, and positive decimal rows:
  `B2`, `$B$2`, `$B2`, `B$2`. Reject row zero and addresses outside the bounded
  table. Header row is 1; data starts at row 2. Headers return text.
- Rectangles `B2:D6`, columns `C:C`, rows `2:2` are table-only operands.
  Allow `$` on each axis of endpoints; qualified rectangles inherit the
  qualifier for the second endpoint (`Rates!B2:B8`). Repeated qualifiers on
  both endpoints must resolve to the same table; mixed-table ranges fail.
- `[@Qty]` or `[@[Unit price]]` means the current row, and `Items[Amount]`
  means the data-only column. Inside header brackets `\]` represents a literal
  `]` and `\\` a literal backslash; spaces, quotes, currency/unit words and
  `|` are literal header text. Unescaped `]` closes the header; `[@[...]]`
  therefore has two unescaped closing brackets without escape ambiguity.
  Unknown backslash escapes fail explicitly.
- Table identifiers with punctuation use backticks, e.g.
  `` `Travel costs`!B2 `` and `` `Travel costs`[Amount] ``; doubled backticks
  escape a backtick. Bare identifiers are ASCII letter/underscore followed
  by letters/digits/underscores; case-insensitive uniqueness applies after
  decoding. Unicode names therefore use the quoted form.
- `sheet[B2]` resolves an inherited ordinary variable; bracket escaping is
  the same as for headers. `sheet` is reserved only as a table name. Ordinary
  variables retain today's naming and normalization rules.
- `#REF!{table-id/row-id/column-id}` is an explicit persisted broken scalar
  reference. A range uses `#REF!{range:binding-id}`; the ledger retains the
  original member identities. These tokens are operands with a diagnostic,
  never values, and never bind to reused coordinates. New UUIDs contain no
  `/`, `}`, or `:`. Manual repair replaces the complete operand.
- Deliberate `@N` reads of earlier prose are allowed inside formulas; physical
  table source lines themselves have no scalar answers. Their bound targets
  follow the unified source transformation, as ordinary line references do.
- Built-in aliases are case-insensitive only in table formulas. Preserve
  custom-function and ordinary-sheet dispatch. Diagnose bare aggregate and
  `previous` operands; `sheet[count]` explicitly resolves the inherited name.

`$` starts a lock only when followed by a complete address; otherwise the
existing money grammar applies. `!` qualifies only after a table identifier
and before an address, otherwise factorial applies. `:` is a range only
between complete table-reference endpoints. Bitwise `|`, time/label syntax,
`@N`, and completion queries retain their existing grammar. Header contents
are never fed through unit or variable recognition. M2 needs a collision
corpus for this grammar before any public syntax freeze.

## Exact structural transformations

Bind scalars to stable target identities, independent of copy locks. Insertions
move their rendered coordinates, including locked coordinates. Deletion
writes a persistent broken operand. Reusing an address never repairs it.

For each rectangular axis, store an inclusive interval over ordered IDs. An
insertion at index `p` before existing `[a,b]` shifts both bounds when `p <= a`,
expands the upper bound when `a < p <= b`, and leaves it unchanged when
`p > b`. Apply independently to rows and columns. An insertion immediately
before the first member is outside; immediately before the last member is
inside. Appending after the final member is outside. Deletion removes included
members; take first/last surviving included identities, never an adjacent
outside member. No survivors on either axis produces a broken range. Header
references remain distinct from data membership.

Whole-column and named-column ranges dynamically include all data rows;
whole-row ranges include all applicable columns. They include their own
formula cell when applicable, so self-membership produces a cycle. Footers
are never numbered data members. View filtering does not change membership.

Copy/fill translates unlocked axis offsets; locks hold targets. Translation
outside bounds persists a broken target. Move retains bindings. Structured
column references always keep their column identity; current-row references
change only row context. Relative column rules anchor to first data row;
rebase offsets and locked identities transactionally on first-row edits. An
empty table has a virtual row-2 anchor. Blank override is distinct from
clearing override. Cross-table move and destructive sort remain deferred.

Rename patches bound operands only, together with their ledger; prose/comments
are untouched. Duplication mints new IDs and remaps internal references while
retaining only visible external targets. Internal clipboard data carries a
version, origin and input/formula policies. External formula paste requires
explicit formula interpretation and binds at its destination.

## Editor choice

Select **read-only inline preview plus Open Table** for v1. Direct inline
editing has not passed real IME/VoiceOver/Find/responder-chain gates and is
therefore not authorized by this spike. Expanded editing uses a view-based
AppKit grid and a source coordinator sharing the document's UndoManager.
Canonical source is the only store; projections must never be saved.

The native harness routes a grid edit through today's editor source replacement
and document Undo; delete → broken marker → disk reload → Undo restores IDs
and bindings. This supports extracting a document-level coordinator in M3,
not retaining a hidden NSTextView as the production grid's source owner.
Restore prose cursor, grid selection and scroll on Return to Sheet. Find
inside the block must open the relevant cell; cross-boundary copy emits
canonical source. Avoid canonical object-replacement characters. The answer
column must skip the full mapped block in both modes.

## Consequences and acceptance

Production engine, storage and editor APIs remain unchanged in M0. The new
executable is disposable and excluded from shipping dependencies. See the
[evidence](../../Spikes/TablesM0/evidence.md) for measurements, native results
and explicit gaps. Architectural direction is accepted: M1 may proceed using
these defaults without another user decision. The reference grammar is to be
implemented and verified in M2. Real IME, VoiceOver, Find and layout tasks are
mandatory integrated-editor gates in M4/M5 and before release, not prerequisites
for source/storage implementation. This is an explicit sequencing adjustment
from the original M0 gate, not a claim that unrun native tests passed. Failed
production gates require fixes or a documented scope revision; the selected
preview fallback does not waive expanded-editor accessibility or source safety.
