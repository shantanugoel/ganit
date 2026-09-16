# Visual system

Ganit looks like a Mac app because it is built from system parts. The tokens
live in `VisualStyle` (GanitEditorUI), and interface modules use them instead
of literal colors, fonts, spacing, or symbol names.

## Color

Only semantic system colors, which follow Dark Mode, Increase Contrast, and the
user's accent color:

| Token | System color | Use |
| --- | --- | --- |
| `primary` | `labelColor` | Source text and answers |
| `secondary` | `secondaryLabelColor` | Labels, dates, and supporting text |
| `tertiary` | `tertiaryLabelColor` | Comments and dividers |
| `failure` | `systemRed` | Failure answers and error underlines |
| `warning` | `systemOrange` | Ambiguity and warning underlines |
| `selectionBackground` | `selectedContentBackgroundColor` | A selected answer |
| `selectionText` | `selectedTextColor` | Text of a selected answer |

Color never carries meaning alone: failures show their message in the answer
column and a dotted underline under the source, which thickens with Increase
Contrast.

## Typography

The system font throughout. Source text is 14 pt at 100% and scales with
View ▸ Bigger/Smaller from 75% to 300%. Answers use the same size with
tabular figures (`monospacedDigitSystemFont`) so digits align; the editor is
never monospaced as a whole. Interpretation values use tabular figures at the
system size, and sidebar dates use the caption text style. No text is smaller
than 10 pt.

## Spacing

| Token | Points | Use |
| --- | --- | --- |
| `tight` | 2 | Stacked lines of one item; sidebar row inset |
| `compact` | 4 | An item's inset from its edge |
| `related` | 6 | Icon to label; grid rows |
| `standard` | 8 | Editor text insets |
| `group` | 12 | Between groups; grid columns |
| `card` | 16 | Popover margins |
| `window` | 20 | Window content margins |

## Symbols

SF Symbols only: `square.and.pencil` (New Sheet), `tray.full` (All Sheets),
`clock` (Recent), `star` (Favorites), `archivebox` (Archive), `trash`
(Trash), `folder` (folders), and `doc.richtext` (Markdown Mode). A test checks
that each symbol exists.

## Materials

Structural chrome gets its material from standard AppKit: the sidebar is a
source-list split view item, the toolbar is a standard `NSToolbar` with a
sidebar tracking separator, and Quick Ganit is a standard titled panel. On
macOS versions with Liquid Glass, these adopt it without custom drawing. The
editor surface is the text view's opaque text background, so source and
answers never sit on vibrancy. Ganit draws no gradients, glass, or custom
visual-effect views; a source scan in `VisualStyleTests` enforces this along
with the color and font rules.
