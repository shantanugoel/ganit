# M0 evidence — 2026-10-01

## Status and scope

Disposable spike implementation and automated verification are complete.
**M0 feasibility is complete**, with the permitted inline preview/Open Table
fallback selected and ADRs 0016/0017 accepted as architectural decisions. The
original M0 native gate sequencing has been explicitly revised in the plan:
full native tasks run on the integrated M4/M5 editor and remain release gates.
They are not claimed as passed. M1 may proceed without a user decision and
will validate/freeze the production wire format; this spike format is experimental.

Worktree branch: `tables`. The original checkout is clean. No production
engine/editor/storage schema constants changed, and shipping products do not
depend on the spike. Experimental plain source fixtures are not supported
Ganit documents and must not be imported into the shipping app.

## Reproduction and hardware

Run the commands in [README](README.md). Measurement command:

```sh
swift build -c release --product GanitTablesM0
/usr/bin/time -l .build/release/GanitTablesM0 --native --fixtures Spikes/TablesM0/Fixtures
```

Measured on Apple M1 Max, 10 CPU cores, 32 GB RAM, arm64, macOS 27.0 build
26A428, Xcode 27.0, Swift 6 package mode. Native framework behavior on macOS 14
has not been measured. Clock/currency context is fixed; no rates or expressions
are sent to any service. This is a single local process measurement, not an
idle/launch benchmark or an integrated editor performance gate.

## Source and bindings

The executable passes the following checks:

- UTF-8 Unicode including composed/decomposed text, emoji, Hindi/CJK,
  U+2028/U+2029, CR/LF/CRLF, quotes, brackets, multiline text, decimal-comma
  source and bitwise `|` survive encode/decode. Source spans map back to exact
  raw block bytes; surrounding prose is retained. Physical lines reuse the
  engine's `SheetSource`, avoiding NSString's extra Unicode line separators.
- Malformed JSON, unknown block version and unterminated blocks retain their
  complete raw source and diagnose without returning a table projection.
  Unknown/unterminated bodies are quarantined from ordinary line syntax.
- Duplicate IDs, conflicting owner occurrences, stale formula fingerprints
  and orphan identities are rejected. Identical formula text in different
  owner cells has separate ledger ownership.
- Delete a row: surviving owners get explicit `#REF!{...}` source plus a
  deleted target in the ledger. Disk save/reload retains both. A coordinate
  reused by a surviving/new row cannot revive that binding. Native document
  Undo restores the original source, IDs and bindings; redo restores deletion.
- The independent prose spike patches two identical bound operand spans into
  persisted deleted markers, leaves an identical comment untouched, and
  verifies byte-exact mixed-line-ending source through disk reload. Token
  discovery and unified mixed-sheet transformations remain M1/M3 work.
- Reference primitive checks cover base-26 A1, mixed/absolute copy locks,
  header/backtick escaping, ordinary-token collisions, translation outside
  bounds, before/interior/after range insertion and endpoint/last-member
  deletion. These are operand primitives, not a complete expression parser.

Checked-in examples include [LF](Fixtures/lf.txt), CR and CRLF byte fixtures,
[deleted target](Fixtures/deleted-target.txt), [compact payload](Fixtures/compact.json),
[malformed block](Fixtures/malformed.txt) and [unknown version](Fixtures/unknown-version.txt).
These are experimental fixtures, not frozen production formats.

## Graph and exact arithmetic

Trace from the seven-node fixture (index/address mapping belongs to the spike):

```text
A2 -> B2, A3      = 5
B2               = 2
A3               = 3
B3 -> C3 -> B3    cycle participants: [B3, C3]
A4 -> B3         blocked, original causes: [B3, C3]
D4               = 7 (independent valid component)
0.1 -> 0.2       = exact Ganit 0.3
```

Both SCC passes use iterative stacks; no recursive dependency evaluation.
Arithmetic reductions use `Evaluator.aggregating` on `EngineValue`, with no
formatted-string or floating-point substitution. The 10,000-cell chain points
forward to the next node and returns exact 10,000 at its first node.

Release graph-only measurements, 21 complete chain generations in one process;
nearest-rank P95 is sorted sample 20, including the first generation:

| Fixture | Cells/nodes and links | Observation |
| --- | --- | --- |
| Long chain | 10,000 nodes, 9,999 links | median 14.110 ms; P95 14.679 ms; max 14.895 ms |
| Shared range membership node | 1,000 members + 1 range node + 9,000 readers; 10,000 links | 14.198 ms, one sample |
| Dense readers | 4,000 nodes; 99,375 links | 17.864 ms, one sample |

The shared-node proof avoids copying 1,000 edges into each of 9,000 readers.
It is not a bounded typed range implementation. No incremental invalidation,
formula parsing, rendering or autosave is included in these timings. Therefore
the 16/50 ms edit-to-visible-answer targets are **unverified**. Cancellation,
clock/rate provenance, inherited custom closures, typed min/max, total-operation
budgets and range-cell-visit ceilings remain later milestone work.

The whole proof process (large verbose and compact encodings, graph datasets
and native window) took 2.85 s real / 2.26 s user / 0.05 s system; maximum RSS
155,697,152 bytes (148.5 MiB), reported peak memory footprint 81,970,064 bytes
(78.2 MiB). These are different operating-system metrics; neither isolates a
single production table. Do not claim a shipped memory gate from this run.

## Source overhead and limit decision

The 10,000-row source fixture uses deterministic 36-character UUID RowIDs,
one column, one input per row and one binding per nonterminal formula.

| Representation | Bytes |
| --- | ---: |
| Three-row verbose fixture, block markers included | 2,430 |
| Three-row compact JSON payload | 683 |
| 10,000-row input strings with a separator each | 68,896 |
| 10,000-row verbose JSON block | 6,978,679 |
| 10,000-row compact JSON payload | 1,884,538 |
| 4,000-row compact JSON payload | 728,744 |

The compact size is payload only; opener/closer and surrounding prose add more.
It interns stable target IDs and uses exact formula-source strings as ledger
fingerprints. Full compact decode → IDs → model matches the original, including
deleted target IDs that are no longer in row membership. The verbose encoding
is rejected. The compact candidate still exceeds the 1,048,576-byte source budget (`SheetExchange.maximumSourceBytes`) at
10,000 cells, so ADR 0017 sets the provisional populated ceiling to **4,000**.
Byte limits remain independent: long text, long formulas or many references
can exhaust the source budget earlier. This is not a promised minimum capacity.
More compact wire records or a different ceiling require measurement/review;
never waive the 1 MB gate to match the engine stress fixture.

## Native proof and explicit inline decision

The AppKit harness constructs a native `NSTableView` and `NSTextField` cell
controls. A field commit action patches canonical source through the existing
`SheetEditorViewController`; the grid has no separate source store or Undo.
Automated checks verify the same UndoManager, source/autosave callback,
Undo/redo, deleted binding disk reload and Undo, cross-boundary canonical source copy from both text and preview,
inline projection refresh after commit,
source-range Find selection, Return-to-prose focus/cursor, retained marked-text
composition and native table/cell accessibility labels/role.

The copy harness initially failed because it requested a modern pasteboard
identifier while this text view advertises `NSStringPboardType`; using its
advertised types passes native selection-copy fidelity. No production copy
behavior was changed to make the spike pass. The preview originally advertised
rich-text clipboard data ahead of plain text; setting the disposable projection
to plain text and mapping its selection to canonical source fixes that path.
Both preview and source copy assertions pass, with an explicit assertion that
Undo refreshed the preview to the restored canonical source.

A read-only native text projection maps its visible table span to the complete
canonical block, preserves full cross-boundary source selection mapping, and
contains no object-replacement character. Its simple answer divider skips the
block. [Native preview capture](Fixtures/native-preview.png) was generated
from the native view and visually inspected. Fixed fixture formatting/divider
geometry is intentional; it is not a production layout or an integrated
answer-column test. The below-table expression is illustrative source, not an
implemented mixed-sheet evaluator.

**Decision: inline preview + Open Table**, with expanded editing as the v1
foundation. Do not enable direct inline editing on these proofs. A production
source coordinator must be extracted from NSTextView ownership in M3; keeping
a hidden editor and rewriting whole JSON blocks is only a disposable proof.

Native task acceptance carried forward from M0 to M4/M5, with explicit expected results:

1. Use a real installed input method to compose cell and prose input, switch
   focus and commit/cancel. No source rewrite or evaluation may disrupt marked
   text, and one committed edit must undo coherently.
2. Run VoiceOver on the native grid, then on the integrated preview. Verify
   spoken header/address/value, selection, editing, errors, Open Table/Return
   actions and document Undo. Labels/role checks do not prove this task.
3. Exercise native Find-panel next/previous and cross-boundary selections;
   table hits must open/locate the cell, source copy must preserve the block,
   and Return must restore scroll/grid selection as well as the prose cursor.
4. Inspect regular and Markdown integrated answer placement at narrow widths,
   scaled text and RTL. The divider must not cross the table and surrounding
   prose must remain editable. The current screenshot covers the spike only.

Real IME, VoiceOver listening, native Find-panel routing and integrated
answer placement were **not run**. Tasks 1–2 are explicit M4 gates; tasks 3–4
are explicit M5 gates, with transition checks repeated there and release
verification in M6. Both ADRs are accepted for architectural direction and M1
may proceed. The fallback decision does not waive expanded-editor accessibility
or source correctness. This sequencing change does not manufacture native
acceptance evidence; the exact production format is still validated/frozen in M1.

## Repository verification

- `swift build`: passed for all products.
- `swift test`: passed, 546 tests across the package (including corpus suites).
- Release spike `--native`: all executable assertions passed.
- Pinned repository formatter and focused spike formatting: passed.
- `scripts/build-app.sh debug` and `scripts/verify-app.sh`: passed.
- `git diff --check`: passed.

Existing dependency deprecation and CoreSpotlight Sendable warnings remain;
no unrelated source changes were made. No sanitizer, macOS 14, native input
method, VoiceOver task, usability study or integrated performance coverage is
claimed by these checks.
