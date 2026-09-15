# Fault tolerance

Ganit's canonical data is each sheet's source file. Every other file can be
recovered from it, and every write is atomic.

## Interrupted saves

Source and metadata are replaced atomically, source first
([sheet files](sheet-files.md)). A library change also creates
`Index/unsynchronized` before writing sheet files and removes it after updating
the index. If Ganit stops at any point:

- the source file is the previous or the new complete version;
- metadata is the previous or new version; a checksum that no longer matches
  the source marks it stale;
- the marker remains when the index may be out of date.

Opening a library with that marker, or with a missing, corrupt, or incompatible
index, runs `recoverAndRebuildIndex()`:

1. metadata with a stale checksum is rewritten for the current source;
2. metadata that cannot be decoded or is missing is moved to `Quarantine/` and
   recreated from the source with a title from its first line and standard
   preferences;
3. the index is rebuilt from the sheet files.

Sheets that still cannot be read, such as non-UTF-8 source or metadata from a
newer schema, are left untouched and reported by the rebuild.

## Verification

`StorageFaultTests` exercises these guarantees:

- A helper process saves a sheet in a loop, alternating two 1.2 MB sources, and
  is killed with `SIGKILL` at random moments twelve times. After every kill the
  source file equals one complete version, and reopening the library yields a
  valid checksum, one sheet, and an index matching the source.
- Corrupt and missing metadata are quarantined and recovered with the source
  intact.
- Files changed without an index update are reindexed on the next open.
- A read-only sheets directory and a full 8 MB disk image reject saves without
  leaving temporary files, and the previous version still loads with a valid
  checksum.
- Index deletion and rebuild, and restoring a daily backup, are covered by
  `SheetIndexTests` and `SheetLibraryTests`.
