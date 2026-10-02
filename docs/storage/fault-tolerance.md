# Fault tolerance

Ganit's canonical data is each sheet's source file. Every other file can be
recovered from it, and every write is atomic.

## Interrupted saves

Source and metadata are replaced atomically, source first
([sheet files](sheet-files.md)). A library change also creates
`Index/unsynchronized` in place, and synchronizes its directory, before
writing sheet files, and removes it after updating the index. A change that
fails partway leaves the marker in place until the next recovery, even if
later changes to other sheets succeed. If Ganit stops at any point:

- the source file is the previous or the new complete version;
- metadata is the previous or new version; a checksum that no longer matches
  the source marks it stale;
- the marker remains when the index may be out of date;
- a hidden temporary file (`.<name>.<UUID>.tmp`) may remain beside the file
  being replaced. It is never read as a sheet.

Opening a library with that marker, or with a missing, corrupt, or incompatible
index, runs `recoverAndRebuildIndex()`:

1. the marker is created, if it is not already there, so a recovery that is
   itself interrupted, even one started by a corrupt index, runs again on
   the next open;
2. temporary files left in `Sheets/` and `Metadata/` by interrupted writes are
   removed where possible: only regular files named exactly
   `.<name>.<UUID>.tmp`, as atomic writes name them; a directory that cannot be
   listed or a file that cannot be removed is skipped;
3. metadata with a stale checksum is rewritten with the checksum of the
   current source, and with a title from its first line unless the user named
   the sheet, keeping every other field;
4. metadata that is missing or cannot be decoded is moved to `Quarantine/`,
   byte for byte, and recreated from the source;
5. the index is rebuilt from the sheet files, and the marker removed unless a
   repair failed.

A repair that fails, as when `Metadata/` or `Quarantine/` cannot be written,
the disk is full, or `Quarantine` is a file, never keeps the library from
opening. The sheet is listed in `unrepairedSheetIDs`, its source untouched;
its undecodable metadata may already be in `Quarantine/`. A sheet whose
metadata could not be recreated cannot be read, so it is also listed in
`unreadableSheetIDs` and counted in the notice the app shows; one whose stale
checksum could not be rewritten stays listed and opens with its current
source. The marker stays, so the next open retries every repair. Recovery
throws, keeping the library from opening, only when the library itself is
unusable: the marker cannot be created in `Index/`, `Sheets/` cannot be
listed, or the index cannot be rebuilt. An `Index/index.sqlite` that is not
a database, has another schema version, or is empty, as an interrupted
creation can leave it, is replaced and rebuilt.

Metadata cannot be decoded when it is not JSON, is truncated, lacks a schema 2
key, holds an invalid value such as an invalid `tables` entry, or has an `id`
other than its file's name, as a metadata file copied from another sheet
does. Trusting such an `id` would save one sheet's source over another's.

Recreated metadata is schema 2 with the sheet's ID, a title from its first
non-blank line (without a heading's `#`), or "Scratch" with a custom title for
the scratch sheet, otherwise no custom title, folder, or
favorite, the active state, standard preferences, empty `tables`, creation
and modification times of the recovery, and the source's checksum. A sheet
whose first line is a table opener is titled with that line,
`@ganit-table 1`; table-aware titles are M3 work.

Recovery writes metadata only. The source file is never written, replaced, or
created, so every table block keeps its bytes: identities, reference ledgers,
`#REF!` markers, and malformed, unknown-version, and unterminated blocks, which
stay quarantined from ordinary calculation. A stale checksum is repaired from
the source on disk; table content is never taken from a backup, the index's
copy of the source, or metadata, which holds only presentation such as
column widths.

Recovery assumes the library is the only writer of its files and that no
write is in progress, as when it opens.

Sheets that still cannot be read, such as non-UTF-8 source or metadata with a
schema other than the current schema 2, are left untouched and listed in the
rebuild's report, which the library keeps as `unreadableSheetIDs`; the app
shows their count once when a window opens. Nothing is migrated or converted.
Metadata without a source file is ignored: it creates no sheet, is not listed,
and is neither quarantined nor removed.

### Repair on demand

Metadata can be damaged while the index stays healthy and no marker exists,
so a full recovery does not run. `SheetLibrary.load(id:)` repairs one sheet
the same way when it is loaded for use: opening it in a window, restoring a
window, renaming, organizing, duplicating, or exporting it, or changing its
display preferences. It rewrites a stale checksum or quarantines and recreates
missing or undecodable metadata, then updates the sheet's index entry, all
marked unsynchronized as any other change is, and reports the repair as
`StoredSheet.metadataRepair`. The open windows' sidebars reload, since the
title may have changed; a restored window shows its sheet this way too. A
sheet with no source file, non-UTF-8 source, or an unsupported schema throws,
and its files are left untouched. A repair that fails leaves the marker, so
the next open retries it, and lists the sheet in `unrepairedSheetIDs`: a stale
sheet is returned unrepaired, while one whose metadata cannot be recreated
throws. An existing scratch sheet that cannot be read or repaired does not
keep the workspace from opening. `SheetStore.load(id:)` only reads.

## Interrupted backups and exports

A day's backup copies metadata, then source, each atomically, before the
library changes any sheet file. A backup without its source is not listed, and
the next save takes it again. An interrupted backup's temporary files stay in
that backup day until pruning removes the day.

An interrupted package export leaves the destination as the complete previous
package, or nothing if there was none, until the new package is swapped in.
A killed export leaves one hidden temporary sibling (`.<name>.ganit.<UUID>.tmp`)
holding the unfinished new package before the swap or the replaced package
after it; Ganit never reads or removes it. An export that fails before the
swap removes its unfinished package. One that fails after swapping, when the
directory cannot be synchronized, reports the error and keeps the replaced
package as that hidden sibling, since the new one may not be durable. Once
the swap is synchronized the export is complete: the replaced package is
removed, and a failure to remove it leaves the sibling without failing the
export. Plain-text export is one atomic file write.

## Verification

Writers report named write points to a test-only, task-local fault handler
(`StorageFaults`, in the `StorageFaults` SPI). Unset, as it always is outside
tests, reaching a point only reads the unset value. The points are: an atomic
write's temporary file created, written, and flushed, the rename, and each
directory synchronization; a package's temporary directory created and fully
assembled, the swap or rename, and removal of the replaced package, reached
only when one was swapped out.

`WriteFaultInjectionTests` records the points each operation reaches, checks
their order, then reruns the operation on a fresh copy of the same files once
per point, throwing there. It covers `SheetStore.save`, `SheetLibrary.save`
with the day's first backup, metadata-only changes, `.ganit` export to a new
and an existing destination with Quick Look files, and plain-text export to a
new and an existing file. The sheet holds two valid tables, one with deleted
`#REF!` bindings, prose naming them, and a malformed block. After every fault:

- the source, package, or exported file is the complete previous or new
  version, byte for byte, with identical table blocks, projections, bindings
  and diagnostics, or absent if it never existed;
- no temporary file or directory remains, except the replaced package, kept
  as a hidden sibling when the export fails or cannot remove it after the
  swap;
- the index marker is on disk exactly when the fault came after its
  directory was synchronized;
- a stale checksum is repaired by `recoverAndRebuildIndex()` with the source
  unchanged, and reopening the library yields a valid checksum and index;
- a backup is listed only once complete, holds the replaced version, and a
  repeated save completes the change.

It also checks that a failed save keeps the index marked unsynchronized after a
later save of another sheet succeeds until recovery runs, after which a
successful save removes the marker again, and that backups of a table-bearing
sheet are taken before each day's first change, restore byte for byte, and
pruning keeps the newest day.

`StorageFaultTests` interrupts writes in a separate helper process with
`SIGKILL`, so no cleanup runs:

- A save, including its backup, and a package export over an existing package
  are killed at each of their write points in turn. The source or package is
  then one complete version, and the index marker is on disk exactly from
  its directory's synchronization on. Reopening the library removes the
  abandoned temporary sheet file and repairs metadata. Beside a package
  exactly one hidden sibling remains: complete new files only before the
  swap, the whole old package after it.
- The helper saves a sheet in a loop, alternating two table-bearing sources of
  about 1 MB, each under the 1 MiB source limit and the 4,000-cell ceiling with
  200 tables, and is killed at random moments twelve times. After every kill
  the source file equals one complete version whose tables parse without
  diagnostics, and reopening the library yields a valid checksum, one sheet,
  no temporary files, and an index matching the source.
- A package export loop with the same sources is killed twelve times; the
  package always reads as one complete version with a valid checksum.
- Corrupt and missing metadata are quarantined and recovered with the source
  intact.
- Files changed without an index update are reindexed on the next open.
- A read-only sheets directory and a full 8 MB disk image reject saves without
  leaving temporary files, and the previous version still loads with a valid
  checksum. A read-only sheets directory holding an abandoned temporary file,
  with the index marked unsynchronized, still opens, recovers, and searches.
- Recovery removes atomic-write temporary files but keeps names such as
  `.tmp`, `.notes.tmp`, `.<UUID>.tmp`, lowercase-UUID names, and directories.
- Every helper process is waited on with a 60-second deadline, after which
  it is killed and the test fails, and each fault test has a five-minute time
  limit, so a stuck child cannot hang the run.
- Index deletion and rebuild, and restoring a daily backup, are covered by
  `SheetIndexTests` and `SheetLibraryTests`.

`CorruptionDrillTests` opens copies of a frozen drill library
(`Tests/GanitDocumentsTests/Fixtures/CorruptionDrill`) whose index is not a
database. Its table-bearing sheets have missing, truncated, non-JSON, invalid
`tables`, stale, and copied metadata; one has CRLF lines, one no final line
break, and one opens with a table block. Each holds two valid tables, one with
deleted `#REF!` bindings, a malformed block, a version 2 block, and an
unterminated block at the end. The library also holds orphaned metadata,
schema 1 and schema 3 metadata, non-UTF-8 source, and a backup of the stale
sheet's older source. Both by full recovery and by loading each sheet with
`load(id:)` under a healthy index:

- every source file keeps its bytes, inode, and modification time;
- each sheet's table blocks, with their identities, bindings, and
  diagnostics, equal those read from the fixture;
- rebuilt metadata has the reset fields above and a valid checksum, and both
  paths write identical metadata; repeating recovery changes nothing;
- each piece of bad metadata is in `Quarantine/` once, byte for byte;
- the stale sheet, which the user named, has metadata differing from the
  fixture only in its checksum, and neither the backup nor the index's older
  copy replaces its source;
- the orphan, unsupported-schema and non-UTF-8 sheets, and healthy metadata
  and backups, are untouched; the unreadable sheets are reported or throw;
- the index lists and finds the recovered sheets by title and source;
- evaluating each recovered sheet, regular or Markdown, gives the fixture's
  answers and table diagnostics, with no answer, declaration, or assistant
  prompt on any block line, and `total` sums only the lines after each block.

`MetadataRepairFaultTests` makes repairs fail, with `Quarantine` a regular
file beside undecodable metadata and with a read-only `Metadata/` beside a
stale checksum, each after a failed on-demand load under a healthy index and
under a corrupt index. The library opens, its healthy sheet loads and is
found, the damaged sheet is reported, its source and metadata are unchanged,
the marker remains, and once the fault is cleared the next open repairs it.
It also checks that stale-checksum repair updates a derived title but keeps a
custom one, that the scratch sheet's recreated metadata keeps "Scratch" on
both paths, and that an empty index file is rebuilt.

`WorkspaceWindowControllerTests` opens sheets whose metadata was deleted or
damaged after indexing from the sidebar and by restoring a window, whose
sidebar then lists the rebuilt title, and opens a workspace whose scratch
sheet cannot be repaired.

None of this simulates power loss: `F_FULLFSYNC` and directory synchronization
are relied on, not tested, for durability across it.
