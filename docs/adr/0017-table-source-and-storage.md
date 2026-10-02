# ADR 0017: Table source and storage

- Status: Accepted (architecture and schema selection; wire format v1 frozen in
  M1 as [table blocks](../storage/table-blocks.md))
- Date: 2026-10-01
- Amended: 2026-10-01 — backward compatibility is explicitly out of scope.
  This supersedes the initial table requirements for earlier-schema readers,
  migration backups, capability-publication barriers and downgrade handling.
  It also overrides general earlier-format support expectations for this feature.
- Amended: 2026-10-02 — M1 froze table block version 1 in
  [table blocks](../storage/table-blocks.md). Its layout supersedes the
  spike-only wording below: owners, targets, operand spans and copy locks are
  positional JSON arrays in the frozen format; a binding's occurrence ordinal
  is its position in its owner's ledger entry and is not stored; and `current`
  (`[@Qty]`) bindings use the `#REF!{range:binding-id}` marker spelling.
- Amended: 2026-10-02 — exact-byte exchange has one exception. Plain-text and
  `.ganit` package import remove exactly one leading UTF-8 byte-order mark
  (`EF BB BF`), an encoding signature some editors add, so a first-line heading
  or table block is still recognized. Library storage, backups and export are
  exact and never add a mark. Consequence: stored text that itself begins with
  U+FEFF keeps it in the library and on export, but loses it when that export
  is imported again. See the [.ganit format](../storage/ganit-format.md).

## Decision

Recognize a block opener at the start of a physical line:
`@ganit-table 1`, followed by JSON records and a physical-line closing marker
`@end-ganit-table`. These spellings are the experimental M0 candidate. Parse
blocks before ordinary or Markdown classification; plain pipe tables remain
prose. JSON escapes embedded CR/LF, quotes and brackets, so payload text cannot
accidentally close its enclosing block. No Unicode normalization. Preserve
all untouched UTF-8 bytes, physical line endings and original source spans.

Malformed JSON, duplicate identities, conflicting bindings or unsupported
versions produce diagnostics and retain their complete raw source. An
unterminated opener quarantines through EOF, including any subsequent opener;
repair is explicit. Do not evaluate quarantined rows as ordinary prose or
substitute the last valid grid. The spike tests this segmentation and recovery.
Production must retain unknown JSON fields and patch individual spans, rather
than decoding and re-encoding an untouched block.

Each table has a 128-bit TableID, each row a RowID, each column a ColumnID;
header identity is `(TableID, ColumnID, header)`, data-cell identity is the
three IDs. Use UUID strings initially. No persistent per-cell UUID or session
LineID. New IDs are minted only for deliberate creation/duplication/repair.
Persist input policies, default unit/currency interpretation, column rule,
explicit overrides (including blank overrides), totals configuration and
ordered IDs. Display widths and focused-view state can remain metadata.

## Reference ledger

Each formula/rule owns its binding occurrences. Bindings retain target IDs,
row/column copy flags, occurrence ordinal and a source fingerprint. Duplicate
formula text in different owning cells has distinct bindings. Invalidated
source cannot reuse its old ledger by occurrence number. Diagnose stale
records without mutating their raw source; an intentional edit drops/rebinds
only its changed owner's occurrences in the same source transaction.

The verbose spike uses SHA-256 of the exact formula bytes. Its revised compact
candidate uses the exact formula string as a collision-free fingerprint and
interns ID strings in a block-local dictionary. Dictionary indexes are wire
pointers to durable IDs, not physical positions; all indexes are decoded to
IDs before transformations. Deleted target IDs remain in the dictionary even
when their rows disappear. Never omit them and thereby bind an old pointer
to a new record. Owner/target tuples, flags and fingerprint are positional
JSON arrays only in the disposable compact spike; this is not a public format.

Readable broken scalars use the marker specified in ADR 0016. Ranges retain
original membership in their deleted binding record. Prose references follow
ADR 0015's rewrite-and-persist pattern: patch successfully rebound qualified
operands and deleted-target markers directly into ordinary source in the
same Undo transaction. No durable prose LineID or global formula byte offset.
The M0 prose spike patches two identical bound occurrences by their supplied
token spans, preserves an identical comment, and verifies byte-exact disk reload.
M1 must prove actual lexical discovery and integration with structural edits;
the native spike demonstrates Undo on cell-owned binding rewrites.

## Size decision

Verbose repeated UUID/SHA records are rejected for production. Even the
experimental compact encoding cannot store the measured 10,000-cell chain
under the existing 1,048,576-byte (1 MiB) budget. Revise the provisional populated
ceiling to **4,000 cells per sheet**, retaining the byte limit as an independent,
often tighter gate. This is a provisional ceiling, not a guaranteed capacity for
long formulas/text or many references. Retain the 10,000-node engine stress
fixture to establish stack safety. M2/M6 must revisit encoding/limits with
shared ranges, dense graphs and measured resource budgets before release.
Never truncate data, bypass the byte limit or advertise 10,000 source cells
based on an engine-only benchmark. Both encodings and byte counts are in the
[M0 evidence](../../Spikes/TablesM0/evidence.md).

## Current format and durable storage

Use **sheet metadata schema 2** and **`.ganit` manifest schema 2** as the sole
supported document/package schemas for this implementation. M1 adds current-
format fixtures and updates the frozen-format registry with its readers and
writers. Reject unsupported schemas clearly. Do not implement earlier-schema
readers, automatic format migration, downgrade export or compatibility shims.
The table block still has its own version for validation and malformed/unknown
block quarantine; versioning does not require supporting older versions.

Use the same current metadata schema for ordinary and table-bearing documents.
There is no per-document legacy upgrade, one-time capability-publication barrier
or migration-specific backup. New writes use the current format directly.
Preserve existing atomic file/package replacement and ordinary backup behavior;
add no separate compatibility storage path.

Canonical source remains authoritative. Interrupted writes must retain either
the previously committed current-format source or a complete replacement, never
partially written source. Rebuild missing/corrupt metadata in the current schema
without discarding source, IDs, bindings or malformed table blocks. Unknown
blocks remain quarantined from ordinary calculations. A stale checksum must
not replace canonical source with a cached projection.

Package import/export supports only the current manifest schema. Plain UTF-8
source remains a supported input/output independent of package schema; retain
its exact bytes, IDs and ledgers. Values-only CSV/Markdown is explicitly lossy.
Current-format backup restore must retain source and references; unsupported
backup schemas are rejected without conversion.

M1 needs fault injection at atomic source/metadata/package write boundaries,
current-format backup restore, stale checksum and missing/corrupt metadata
fixtures. These prove present-format durability, not migration or interoperability
with earlier binaries. The M0 disk round trip does not establish production
save durability.

## Resolution boundary

Source recovery, durable binding ownership and compact encoding feasibility
have executable prototypes. Precise compact wire layout remains experimental
until M1 defines and verifies its frozen-format fixtures, binding validation
and recovery checks. Architecture and schema choices are accepted; M1 may
proceed without additional user approval. Do not publish the experimental
spike encoding as a supported format. M2 owns full formula-grammar collision
tests; M4/M5 own the native acceptance tasks recorded in M0. See ADR 0016 for
editor ownership, reference transformations and the inline-preview decision.
