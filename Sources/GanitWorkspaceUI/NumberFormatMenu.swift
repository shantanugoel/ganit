import AppKit
import GanitFormatting

/// The number formats the Format menu offers, carried in menu item tags
/// because that is the number an `NSMenuItem` holds.
///
/// A sheet can be written to any number of decimals; these are the counts
/// worth a menu item.
enum NumberFormatMenu {
  static let decimalCounts = [0, 2, 4]

  static func tag(of display: NumberDisplay) -> Int {
    switch display {
    case .automatic:
      return 0
    case .fixedDecimals(let places):
      return places + 1
    case .scientific:
      return -1
    }
  }

  static func display(forTag tag: Int) -> NumberDisplay {
    switch tag {
    case 0:
      return .automatic
    case -1:
      return .scientific
    default:
      return .fixedDecimals(tag - 1)
    }
  }

  static func title(of display: NumberDisplay) -> String {
    switch display {
    case .automatic:
      return localized("menu.automaticFormat", "Automatic")
    case .fixedDecimals(0):
      return localized("menu.wholeNumbers", "Whole Numbers")
    case .fixedDecimals(let places):
      return String(
        format: localized("menu.fixedDecimals", "%d Decimals"),
        places
      )
    case .scientific:
      return localized("menu.scientific", "Scientific")
    }
  }
}

extension MainMenu {
  /// Automatic, the fixed-decimal counts, and scientific, in that order.
  static func numberFormatItems() -> [NSMenuItem] {
    let displays: [NumberDisplay] =
      [.automatic] + NumberFormatMenu.decimalCounts.map { .fixedDecimals($0) } + [.scientific]
    return displays.map { display in
      let item = NSMenuItem(
        title: NumberFormatMenu.title(of: display),
        action: #selector(WorkspaceCommands.setNumberFormat(_:)),
        keyEquivalent: ""
      )
      item.tag = NumberFormatMenu.tag(of: display)
      return item
    }
  }
}
