# Recovering your sheets

Every instruction here is rehearsed by `RecoveryRehearsalTests` against a real
library on disk, and the automatic recovery paths by `StorageFaultTests`,
`SheetLibraryTests`, and `RateSnapshotStoreTests`.

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

## Return to an older Ganit

Sheets that a newer Ganit saved in a newer format are left untouched: an older
version skips them, reports them as unreadable, and never rewrites or deletes
their files. Every other sheet keeps working. Open the library in the newer
Ganit again to use those sheets.

## Damaged exchange rates

Nothing to do. If the current rate snapshot is damaged, Ganit falls back to
the newest intact one of the eight it keeps, and a rejected download never
replaces good rates. With no usable snapshot, conversions ask for a manual
rate such as `1 USD = 83 INR`.
