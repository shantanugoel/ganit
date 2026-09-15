import AppKit

/// Ganit's visual tokens. Every color is a semantic system color that adapts
/// to Dark Mode, Increase Contrast, and accent color; type is the system font;
/// symbols are SF Symbols. Views use these names instead of literals.
public enum VisualStyle {
  public enum Color {
    /// Answers and source text.
    public static let primary = NSColor.labelColor
    /// Labels, dates, and other supporting text.
    public static let secondary = NSColor.secondaryLabelColor
    /// Comments and dividers.
    public static let tertiary = NSColor.tertiaryLabelColor
    /// Failure answers and error underlines, always paired with message text
    /// or a dotted underline.
    public static let failure = NSColor.systemRed
    /// Ambiguity and warning underlines.
    public static let warning = NSColor.systemOrange
    public static let selectionBackground = NSColor.selectedContentBackgroundColor
    public static let selectionText = NSColor.selectedTextColor
  }

  public enum Typography {
    /// The editor's default size; View ▸ Bigger scales from it.
    public static let editorSize: CGFloat = 14
    /// The smallest size any text may use.
    public static let minimumSize: CGFloat = 10

    public static func source(scale: CGFloat) -> NSFont {
      .systemFont(ofSize: editorSize * scale)
    }

    /// Answers use tabular figures so digits align down the column.
    public static func answer(scale: CGFloat) -> NSFont {
      .monospacedDigitSystemFont(ofSize: editorSize * scale, weight: .regular)
    }

    public static var detailValue: NSFont {
      .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    public static var caption: NSFont {
      .preferredFont(forTextStyle: .caption1)
    }
  }

  /// Spacing steps, in points.
  public enum Spacing {
    /// Between stacked lines of one item.
    public static let tight: CGFloat = 2
    /// Between an item and its edge.
    public static let compact: CGFloat = 4
    /// Between an icon and its label, or rows of a grid.
    public static let related: CGFloat = 6
    /// Text insets.
    public static let standard: CGFloat = 8
    /// Between groups and grid columns.
    public static let group: CGFloat = 12
    /// Popover and card margins.
    public static let card: CGFloat = 16
    /// Window content margins.
    public static let window: CGFloat = 20
  }

  public enum Symbol {
    public static let newSheet = "square.and.pencil"
    public static let allSheets = "tray.full"
    public static let recent = "clock"
    public static let favorites = "star"
    public static let archive = "archivebox"
    public static let trash = "trash"
    public static let folder = "folder"

    public static let all = [newSheet, allSheets, recent, favorites, archive, trash, folder]
  }
}
