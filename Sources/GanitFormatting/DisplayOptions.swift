/// How a sheet writes its answers.
///
/// The defaults are how Ganit writes them without being asked: digits grouped
/// the way the sheet's locale groups them, and as many decimals as the value
/// needs. A value is kept whole whatever this says, so these choices change
/// what an answer looks like and never what it is. Copying still yields full
/// precision, and money keeps its currency's decimals.
public struct DisplayOptions: Codable, Equatable, Sendable {
  public static let standard = DisplayOptions()

  /// Groups digits as the locale does: `1,234,567` rather than `1234567`.
  public var groupsDigits: Bool

  /// How many decimals a number shows, and whether it is written as a power
  /// of ten.
  public var numbers: NumberDisplay

  public init(groupsDigits: Bool = true, numbers: NumberDisplay = .automatic) {
    self.groupsDigits = groupsDigits
    self.numbers = numbers
  }
}

/// The forms a number can take on a sheet. They are exclusive: a fixed number
/// of decimals and a power of ten describe the same digits two ways, so a
/// sheet asks for one of them.
public enum NumberDisplay: Codable, Equatable, Sendable {
  /// The decimals the value needs, up to the sheet's precision.
  case automatic

  /// Always this many decimals, so `1.5` reads `1.50` at two and `2` reads
  /// `2.00`. Displays clamp the count to `decimalLimit`.
  case fixedDecimals(Int)

  /// A power of ten, `1.2e6`, which the grammar reads back.
  case scientific

  /// The most decimals a fixed display can ask for. Past this the digits stop
  /// being the value's, because the sheet's precision runs out first.
  public static let decimalLimit = 15
}
