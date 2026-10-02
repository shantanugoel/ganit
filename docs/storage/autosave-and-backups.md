# Autosave, backups, and restore

## Library

`SheetLibrary` combines the [sheet files](sheet-files.md), the
[derived index](index.md), and daily backups under one root. The app keeps it
in its Application Support directory, named by bundle identifier. Opening a
library rebuilds the index first when it is missing or was replaced.

Saving a sheet sets its modification time and derives its title from the first
non-blank line, using a heading's title without `#`, writes the files
atomically, and updates the index.

## Autosave

Each workspace window saves its sheet through `SheetAutosaver`:

- one second after edits settle, restarting the delay on every edit;
- immediately when the window stops being key, including when Ganit is
  deactivated, when the window closes, and when Ganit terminates.

A failed save presents the error on the window and leaves the edits unsaved,
so the next edit or save request tries again.

## Backups

Before a sheet's files are replaced for the first time on a day, the library
copies them into `Backups/YYYY-MM-DD/`, which mirrors the library layout with
`Sheets/` and `Metadata/`. Metadata is copied before source, so any backup that
has source is complete. Days use the library's time zone.

After each new backup, whole days are removed oldest first while there are more
than 30 days or they exceed 100 MB together; the newest day always remains.

## Restore Previous Version

File ▸ Restore Previous Version… saves pending edits, then lists the sheet's
backup days, newest first. Restoring replaces the editor's text with the
chosen backup as one undoable edit, which autosave saves like any other. Because
that save is itself protected by the day's backup, a restore never discards the
version it replaces. `SheetLibraryTests` restores a backup and verifies the
saved result.

## Schema versions

Metadata schema 2 is the only document format, as
[ADR 0017](../adr/0017-table-source-and-storage.md) decides. Any other version,
including `1`, fails explicitly and is left untouched. There are no legacy
readers, migrations, or migration backups; backups hold current-format files,
and restoring one with another schema fails the same way.
