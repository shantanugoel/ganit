import GanitFormatting

/// The number formats the Format menu and an answer's menu offer, carried in menu item tags
/// because that is the number an `NSMenuItem` holds.
///
/// A sheet can be written to any number of decimals; these are the counts
/// worth a menu item.
public enum NumberFormatMenu {
  static let decimalCounts = [0, 2, 4]

  /// Automatic, the fixed-decimal counts, scientific, and the other bases, in
  /// menu order.
  public static let displays: [NumberDisplay] =
    [.automatic] + decimalCounts.map { .fixedDecimals($0) }
    + [.scientific, .hexadecimal, .binary, .fraction]

  public static func tag(of display: NumberDisplay) -> Int {
    switch display {
    case .automatic:
      return 0
    case .fixedDecimals(let places):
      return places + 1
    case .scientific:
      return -1
    case .hexadecimal:
      return -2
    case .binary:
      return -3
    case .fraction:
      return -4
    }
  }

  public static func display(forTag tag: Int) -> NumberDisplay {
    switch tag {
    case 0:
      return .automatic
    case -1:
      return .scientific
    case -2:
      return .hexadecimal
    case -3:
      return .binary
    case -4:
      return .fraction
    default:
      return .fixedDecimals(tag - 1)
    }
  }

  public static func title(of display: NumberDisplay) -> String {
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
    case .hexadecimal:
      return localized("menu.hexadecimal", "Hexadecimal")
    case .binary:
      return localized("menu.binary", "Binary")
    case .fraction:
      return localized("menu.fractions", "Fractions")
    }
  }
}
