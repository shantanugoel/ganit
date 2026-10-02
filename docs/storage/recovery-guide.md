# Recovering your sheets

Every instruction here is rehearsed by `RecoveryRehearsalTests` against a real
library on disk, and the automatic recovery paths by `StorageFaultTests`,
`CorruptionDrillTests`, `SheetLibraryTests`, and `RateSnapshotStoreTests`.

Ganit keeps its library in its sandbox container:

```text
~/Library/Containers/com.shantanugoel.Ganit/Data/Library/Application Support/com.shantanugoel.Ganit/
```

`Sheets/` holds each sheet's source as plain UTF-8 text, the canonical copy.
`Metadata/`, `Index/`, and `Backups/` sit beside it.

## After a crash or power loss

Nothing to do. Every save is atomic, so each sheet is its previous or new
complete version. The next launch rewrites stale metadata, moves unreadable
metadata to `Quarantine/`, and rebuilds the index from the sheet files.

## A sheet's metadata is damaged or missing

Nothing to do. Opening the sheet, or the next launch that rebuilds the index,
moves damaged metadata to `Quarantine/` and recreates it from the sheet's text,
which is never changed: its calculations and tables, including ones Ganit
can't read yet, are kept exactly. The sheet's title then follows its first line,
and its name, folder, favorite, archive or trash state, number settings, and
column widths go back to their defaults; set them again if you need them. The
quarantined file stays in `Quarantine/` for reference. A metadata file whose
sheet text is gone is ignored. If Ganit can't write the repaired metadata, for
example because the disk is full or the library folder's permissions were
changed, the library still opens, the sheet's text is left as it is, and
Ganit tries again at the next launch once the problem is fixed.

## Undo a day's mistakes

Open the sheet and choose **File ▸ Restore Previous Version…**, then pick a
day. Ganit keeps the version from before each day's first change for 30 days,
up to 100 MB. The restore is an undoable edit, and it is backed up like any
other change.

## Move to a new Mac or reinstall

Quit Ganit, copy the folder above to the same place on the new Mac, and open
Ganit. The library opens with every sheet, title, folder, and backup.

## Keep an independent copy

Choose **File ▸ Export…** and **Ganit Sheet** for each sheet. A `.ganit`
package holds the exact source, title, and preferences. Import it with
**File ▸ Import…** or by opening it in Finder; a package keeps its sheet's
identity when that sheet is not already in the library. The source is also
plain text you can read without Ganit: `source.txt` inside the package.

## Sheets in an unsupported format

Ganit reads only the current metadata format, schema 2. A sheet whose metadata
has any other schema, such as `1` or a later version, is left untouched:
Ganit never rewrites, converts, or deletes its files, and every other sheet
keeps working. When Ganit rebuilds its index, such as the first launch after
the format changed, it leaves these sheets out of the library and, when a
window opens, says how many sheets it couldn't open. Opening one, such as the
scratch sheet, explains which format it was saved in. The sheet's source in
`Sheets/` is still plain text you can read or import.

## Damaged exchange rates

Nothing to do. If the current rate snapshot is damaged, Ganit falls back to
the newest intact one of the eight it keeps, and a rejected download never
replaces good rates. With no usable snapshot, conversions ask for a manual
rate such as `1 USD = 83 INR`.
