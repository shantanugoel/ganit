# Data migration

`DocumentMigration` contains all conversion rules. Current readers and
writers use schema 2. The editor and engine need no schema 1 checks.

## Library startup

`SheetLibrary.init` calls the module before index recovery. The module finds
schema 1 metadata beside source files in the library and daily backups.
It validates the converted metadata and the sheet ID before replacement.
Malformed metadata and unknown schemas stay unchanged for normal recovery
or the unsupported format notice.

For each valid schema 1 file, set `schemaVersion` to 2 and add empty `tables`
settings. Add missing display settings with the defaults that schema 1
readers used. Keep IDs, titles, folders, states, favorites, timestamps,
checksums, and existing preferences. Source files stay unchanged.

Before replacement, write the original metadata to
`MigrationBackups/schema-1/<relative path>`. Use atomic writes for both files.
Keep these original files outside normal daily backup limits. The metadata
backup has no source copy because migration does not change source.

Mark the index unsynchronized before the first replacement. Normal library
recovery rebuilds the index after conversion. If a write fails, startup stops.
At the next launch, retry schema 1 files. Already converted files need no
replacement. If interruption occurs after the final replacement, the index
marker still causes recovery. Do not replace an existing original backup.
A different backup causes an error.

The app shows “Updating saved sheets” before the first write. The message
explains the possible delay and shows completed and total file counts. No
message appears when there are no files to convert. Startup conversion is
synchronous because window restoration requires the library. The window
is redrawn at each progress update; other app actions wait for startup.

## Package import

`SheetExchange.read` calls the same module for manifests. Convert schema 1
JSON in memory, then use the current manifest reader. Keep source handling,
size limits, and checksum checks. Do not write to the selected package.
Import and export create current format data.

## Limits and checks

Only schema 1 converts to schema 2. Do not infer formats from absent version
fields. Unknown versions stay unsupported. Conversion does not provide
old app support for the new format.

Tests check original metadata, source bytes, daily backups, old display
defaults, package import, repeated startup, and interrupted replacement.
Storage fault injection checks retry before and after an atomic rename.
