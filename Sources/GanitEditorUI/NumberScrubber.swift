import Foundation
import GanitEngine

/// A number written in a line, and the digits that step it.
///
/// Scrubbing changes the digits a person points at, not the value a line
/// computes, so it works on the literal the lexer found there. Dragging right
/// raises those digits and dragging left lowers them, stopping at zero: a sign
/// in front of a number belongs to the expression rather than to the literal.
///
/// A step is one unit of the place `scale` names, counted from the decimal
/// point: `2` is hundredths, `0` is units, `-1` is tens. A literal keeps the
/// decimals it was written with, and gains decimals when a finer step needs
/// them.
struct ScrubbableNumber: Equatable {
  /// The literal's range in the line, in UTF-16 code units, as text views
  /// count.
  let range: NSRange
  /// The digits as written, such as `2,100` or `0.50`.
  let text: String
  /// The place the literal's last digit occupies, so `0.50` is `2`.
  let scale: Int
  private let groupsDigits: Bool

  /// The number written at `offset` in `line`, if one is written there.
  ///
  /// Only plain decimal digits can be stepped. Powers of ten, hexadecimal,
  /// binary, and octal literals say something about how a number is written
  /// that stepping would have to guess at, so they are left alone.
  init?(in line: String, at offset: Int, configuration: LexingConfiguration) {
    let tokens = Lexer(source: line, configuration: configuration).lex().tokens
    for token in tokens {
      guard let range = Self.utf16Range(of: token.range, in: line),
        offset >= range.location, offset <= range.location + range.length
      else {
        continue
      }
      guard case .number(let literal) = token.kind else {
        continue
      }
      let scale: Int
      switch literal {
      case .integer(_, .decimal):
        scale = 0
      case .decimal(_, let fractionalDigitCount, 0):
        scale = fractionalDigitCount
      case .integer, .decimal:
        return nil
      }
      let text = (line as NSString).substring(with: range)
      self.range = range
      self.text = text
      self.scale = scale
      // A number keeps the separators it was written with. Digits too few to
      // show one say nothing about grouping, so `999` stepping into four digits
      // takes the grammar's separator rather than deciding to do without it.
      if let separator = configuration.groupingSeparator {
        let whole = text.prefix { $0 != configuration.decimalSeparator }
        groupsDigits =
          whole.contains(separator)
          || whole.count <= configuration.primaryGroupingSize
      } else {
        groupsDigits = false
      }
      return
    }
    return nil
  }

  /// This literal stepped by `steps` units of the place `scale` names, or
  /// `nil` when the digits are more than stepping can carry.
  func stepped(
    by steps: Int,
    scale: Int,
    configuration: LexingConfiguration
  ) -> String? {
    let places = max(self.scale, max(scale, 0))
    guard let unit = Self.power(of: 10, to: places - scale),
      let scaled = Self.scaled(text, to: places, configuration: configuration)
    else {
      return nil
    }
    let (moved, overflow) = steps.multipliedReportingOverflow(by: unit)
    guard !overflow else {
      return nil
    }
    let (stepped, carried) = scaled.addingReportingOverflow(moved)
    guard !carried else {
      return nil
    }
    return written(max(0, stepped), places: places, configuration: configuration)
  }

  /// `value` in units of the last place, written the way this literal is: the
  /// same grouping, and the same decimal separator.
  private func written(
    _ value: Int,
    places: Int,
    configuration: LexingConfiguration
  ) -> String? {
    guard let divisor = Self.power(of: 10, to: places) else {
      return nil
    }
    var whole = String(value / divisor)
    if groupsDigits, let separator = configuration.groupingSeparator {
      whole = Self.grouped(whole, by: separator, configuration: configuration)
    }
    guard places > 0 else {
      return whole
    }
    let fraction = String(
      String(repeating: "0", count: places) + String(value % divisor)
    ).suffix(places)
    return whole + String(configuration.decimalSeparator) + fraction
  }

  private static func scaled(
    _ text: String,
    to places: Int,
    configuration: LexingConfiguration
  ) -> Int? {
    var whole = ""
    var fraction = ""
    var isFraction = false
    for character in text {
      if character == configuration.decimalSeparator {
        isFraction = true
      } else if character != configuration.groupingSeparator {
        isFraction ? fraction.append(character) : whole.append(character)
      }
    }
    guard fraction.count <= places, let value = Int(whole + fraction),
      let shift = power(of: 10, to: places - fraction.count)
    else {
      return nil
    }
    let (scaled, overflow) = value.multipliedReportingOverflow(by: shift)
    return overflow ? nil : scaled
  }

  /// The digits of a whole number separated the way the sheet's grammar reads
  /// them: the primary group last, and the rest in secondary groups.
  private static func grouped(
    _ digits: String,
    by separator: Character,
    configuration: LexingConfiguration
  ) -> String {
    guard digits.count > configuration.primaryGroupingSize else {
      return digits
    }
    var groups = [String(digits.suffix(configuration.primaryGroupingSize))]
    var remaining = Substring(digits.dropLast(configuration.primaryGroupingSize))
    while !remaining.isEmpty {
      let size = min(configuration.secondaryGroupingSize, remaining.count)
      groups.append(String(remaining.suffix(size)))
      remaining = remaining.dropLast(size)
    }
    return groups.reversed().joined(separator: String(separator))
  }

  private static func power(of base: Int, to exponent: Int) -> Int? {
    guard exponent >= 0 else {
      return nil
    }
    var result = 1
    for _ in 0..<exponent {
      let (next, overflow) = result.multipliedReportingOverflow(by: base)
      guard !overflow else {
        return nil
      }
      result = next
    }
    return result
  }

  /// A lexer counts in UTF-8 code units and graphemes; a text view counts in
  /// UTF-16 code units.
  private static func utf16Range(of range: SourceRange, in line: String) -> NSRange? {
    guard range.graphemeUpperBound <= line.count else {
      return nil
    }
    let lower = line.index(line.startIndex, offsetBy: range.graphemeLowerBound)
    let upper = line.index(line.startIndex, offsetBy: range.graphemeUpperBound)
    return NSRange(
      location: line.utf16.distance(from: line.startIndex, to: lower),
      length: line.utf16.distance(from: lower, to: upper)
    )
  }
}
