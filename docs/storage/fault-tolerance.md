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

1. temporary files left in `Sheets/` and `Metadata/` by interrupted writes are
   removed where possible: only regular files named exactly
   `.<name>.<UUID>.tmp`, as atomic writes name them; a directory that cannot be
   listed or a file that cannot be removed is skipped, so cleanup never keeps
   a library from opening;
2. metadata with a stale checksum is rewritten for the current source;
3. metadata that cannot be decoded or is missing is moved to `Quarantine/` and
   recreated from the source with a title from its first line and standard
   preferences;
4. the index is rebuilt from the sheet files.

Recovery assumes the library is the only writer of its files and that no
write is in progress, as when it opens.

Sheets that still cannot be read, such as non-UTF-8 source or metadata with a
schema other than the current schema 2, are left untouched and listed in the
rebuild's report, which the library keeps as `unreadableSheetIDs`; the app
shows their count once when a window opens. Nothing is migrated or converted.

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

None of this simulates power loss: `F_FULLFSYNC` and directory synchronization
are relied on, not tested, for durability across it.
