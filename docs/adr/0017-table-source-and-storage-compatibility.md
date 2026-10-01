# ADR 0017: Table source and storage compatibility

- Status: Accepted (architecture and schema selection; wire-format freeze in M1)
- Date: 2026-10-01

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

## Compatibility and migration order

Reserve **sheet metadata schema 2**, **`.ganit` manifest schema 2**, and required
capability **`calculation-tables-v1`** for the first table-capable implementation.
Version-1 ordinary documents remain readable. Do not change current constants
or frozen-format tests in M0. M1 must add versioned fixtures and update the
frozen-format registry together with readers/writers. Schema 2 must reject
unknown required capabilities explicitly; malformed source can still be
retained and saved under a table-capable envelope.

Before the first table-bearing save of a legacy document, durably capture its
immediate pre-migration source and metadata, independently of the daily backup.
Then atomically write and fsync table-capable schema/capability metadata and
its directory **before** writing table source. Only after this durable barrier
may source and normal metadata/checksum saves proceed. A crash after the barrier
but before source publication yields table-capable metadata with the old source,
which a modern reader accepts. A crash must never yield old metadata and new
table source. Keep the migration backup through verification.

Modern recovery inspects canonical source for any table opener, including
unknown/malformed versions. Missing/corrupt metadata must be recovered to a
capable envelope, never a version-1 envelope around table syntax. Package
export/import uses schema-2 manifests and refuses unsupported downgrade.
Existing atomic package replacement remains valid; plain-source export retains
IDs and ledgers. Values-only CSV/Markdown is explicitly lossy.

Old binaries reject known-new manifest/metadata versions where they already
check versions. Raw text import, missing-metadata reconstruction and arbitrary
older binaries are outside that protection: no claim of retroactive safety.
M1 needs crash injection at every backup/barrier/source/metadata boundary,
backup restore, stale checksum, corruption and modern recovery fixtures.
The M0 disk round trip does not establish production migration durability.

## Resolution boundary

Source recovery, durable binding ownership and compact encoding feasibility
have executable prototypes. Precise compact wire layout remains experimental
until M1 defines and verifies its frozen-format fixtures, binding validation
and recovery checks. Architecture and schema choices are accepted; M1 may
proceed without additional user approval. Do not publish the experimental
spike encoding as a supported format. M2 owns full formula-grammar collision
tests; M4/M5 own the native acceptance tasks recorded in M0. See ADR 0016 for
editor ownership, reference transformations and the inline-preview decision.
