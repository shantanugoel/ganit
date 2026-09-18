import Foundation
import GanitEngine

public enum FormattingError: Error, Hashable, Sendable {
  case outputTooLong
  case internalFailure

  public var code: String {
    switch self {
    case .outputTooLong:
      return "formatting.outputTooLong"
    case .internalFailure:
      return "formatting.internalFailure"
    }
  }

  public var messageKey: String {
    "error.\(code)"
  }
}

public struct FormattedDiagnostic: Hashable, Sendable {
  public let code: String
  public let severity: DiagnosticSeverity
  public let ranges: [SourceRange]
  public let message: String
  public let fixIts: [DiagnosticFixIt]

  public init(
    code: String,
    severity: DiagnosticSeverity,
    ranges: [SourceRange],
    message: String,
    fixIts: [DiagnosticFixIt] = []
  ) {
    self.code = code
    self.severity = severity
    self.ranges = ranges
    self.message = message
    self.fixIts = fixIts
  }
}

public struct FormattingLimits: Hashable, Sendable {
  public let maximumCharacters: Int

  public init(maximumCharacters: Int = 100_000) {
    precondition(maximumCharacters > 0)
    self.maximumCharacters = maximumCharacters
  }

  public static let `default` = FormattingLimits()
}

public struct FormattedResult: Hashable, Sendable {
  public let display: String
  public let fullPrecision: String
  public let isApproximate: Bool
  /// An exact value whose display, marked `≈`, dropped digits; full
  /// precision still has them all.
  public let isRounded: Bool

  public init(
    display: String,
    fullPrecision: String,
    isApproximate: Bool,
    isRounded: Bool = false
  ) {
    self.display = display
    self.fullPrecision = fullPrecision
    self.isApproximate = isApproximate
    self.isRounded = isRounded
  }
}

public struct NumericResultFormatter: Sendable {
  private let context: EvaluationContext
  private let limits: FormattingLimits
  private let convention: LocaleNumberConvention
  private let display: DisplayOptions

  public init(
    context: EvaluationContext,
    limits: FormattingLimits = .default,
    display: DisplayOptions = .standard
  ) {
    self.context = context
    self.limits = limits
    self.display = display
    convention = LocaleNumberConvention(
      localeIdentifier: context.localeIdentifier
    )
  }

  public func format(_ value: NumericValue) throws -> FormattedResult {
    switch value {
    case .integer(let integer):
      let canonical = try canonicalInteger(integer)
      // Rounded like a decimal for display, so a huge integer's power of ten
      // shows the context's digits rather than every one.
      let shown =
        Self.isOutsideDigitRange(canonical)
        ? try canonicalDecimal(
          try DecimalValue(coefficient: integer, scale: 0).decimal(
            significantDigits: context.precision.significantDecimalDigits,
            rule: context.precision.roundingRule))
        : canonical
      return try exactResult(
        try written(value, asDecimal: shown, isRounded: shown != canonical),
        fullPrecision: canonical
      )

    case .rational(let rational):
      // The fraction is the value; the display is it rounded to the
      // context's precision, as a fraction is unreadable as an answer.
      let canonical = try joined(
        try canonicalInteger(rational.numerator),
        "/",
        try canonicalInteger(rational.denominator)
      )
      guard
        let rounded = try? rational.decimal(
          significantDigits: context.precision.significantDecimalDigits,
          rule: context.precision.roundingRule
        )
      else {
        throw FormattingError.internalFailure
      }
      return try exactResult(
        try written(
          value, asDecimal: try canonicalDecimal(rounded),
          isRounded: isRounded(value, as: rounded)),
        fullPrecision: canonical
      )

    case .decimal(let decimal):
      // Like a fraction: exact underneath, shown to the context's precision
      // without the zeroes an operand's scale carried in. The canonical form
      // bounds the scale before rounding allocates its power of ten.
      let canonical = try canonicalDecimal(decimal)
      let rounded = try decimal.decimal(
        significantDigits: context.precision.significantDecimalDigits,
        rule: context.precision.roundingRule
      )
      return try exactResult(
        try written(
          value, asDecimal: try canonicalDecimal(rounded),
          isRounded: isRounded(value, as: rounded)),
        fullPrecision: canonical
      )

    case .approximate(let approximate):
      let displayNumber = try approximateDisplay(approximate)
      let display = try joined("≈ ", displayNumber)
      let fullPrecision = try joined(
        "≈ ",
        String(approximate.estimate)
      )
      return FormattedResult(
        display: display,
        fullPrecision: fullPrecision,
        isApproximate: true
      )
    }
  }

  private func exactResult(
    _ shown: (display: String, isRounded: Bool),
    fullPrecision: String
  ) throws -> FormattedResult {
    let display = shown.isRounded ? try joined("≈ ", shown.display) : shown.display
    try validateLength(display.count)
    try validateLength(fullPrecision.count)
    return FormattedResult(
      display: display,
      fullPrecision: fullPrecision,
      isApproximate: false,
      isRounded: shown.isRounded
    )
  }

  /// Whether `shown`, `value` rounded for display, dropped digits. A value
  /// too large to compare is taken as rounded.
  private func isRounded(_ value: NumericValue, as shown: DecimalValue) throws -> Bool {
    let exact = try value.rounded(fractionDigits: max(shown.scale, 0))
    guard !exact.isRounded, shown.scale < 0 else {
      return exact.isRounded
    }
    return (try? canonicalDecimal(exact.value) != canonicalDecimal(shown)) ?? true
  }

  private func canonicalInteger(_ value: IntegerValue) throws -> String {
    let minimumDigits =
      value.magnitudeBitWidth == 0
      ? 1
      : max(
        1,
        Int(
          Double(value.magnitudeBitWidth - 1) * 0.301_029_995_663_981_2
        )
      )
    try validateCombinedLength([
      minimumDigits, value.isNegative ? localeMinusSign.count : 0,
    ])
    let digits = value.canonicalDigits
    try validateLength(digits.count)
    return digits
  }

  func canonicalDecimal(_ value: DecimalValue) throws -> String {
    let coefficient = try canonicalInteger(value.coefficient)
    let isNegative = coefficient.first == "-"
    let magnitude = isNegative ? String(coefficient.dropFirst()) : coefficient
    let sign = isNegative ? "-" : ""
    let body: String

    if value.scale == 0 {
      body = magnitude
    } else if value.scale > 0 {
      if magnitude.count <= value.scale {
        let zeroCount = value.scale - magnitude.count
        try validateCombinedLength([sign.count, 2, zeroCount, magnitude.count])
        body = "0." + String(repeating: "0", count: zeroCount) + magnitude
      } else {
        let split = magnitude.index(
          magnitude.endIndex,
          offsetBy: -value.scale
        )
        body = magnitude[..<split] + "." + magnitude[split...]
      }
    } else {
      let zeroCount = -value.scale
      try validateCombinedLength([sign.count, magnitude.count, zeroCount])
      body = magnitude + String(repeating: "0", count: zeroCount)
    }

    let result = sign + body
    try validateLength(result.count)
    return result
  }

  /// An exact value as this sheet writes it, from the digits it would write
  /// without being asked, which `isRounded` says dropped some. Rounding to a
  /// fixed number of decimals runs on the value rather than on these digits,
  /// so a fraction rounds from the fraction.
  private func written(
    _ value: NumericValue,
    asDecimal canonical: String,
    isRounded: Bool
  ) throws -> (display: String, isRounded: Bool) {
    switch display.numbers {
    case .automatic:
      return (
        Self.isOutsideDigitRange(canonical)
          ? try scientific(canonical) : try localizeDecimal(canonical), isRounded
      )
    case .fixedDecimals(let places):
      let (rounded, isRounded) = try value.rounded(
        fractionDigits: min(max(places, 0), NumberDisplay.decimalLimit)
      )
      return (try localizeDecimal(try canonicalDecimal(rounded)), isRounded)
    case .scientific:
      return (try scientific(canonical), isRounded)
    case .hexadecimal, .binary:
      guard case .integer(let integer) = value else {
        // A value with no whole digits in that base keeps its usual form.
        return (try localizeDecimal(canonical), isRounded)
      }
      let radix: NumericRadix = display.numbers == .hexadecimal ? .hexadecimal : .binary
      let marker = radix == .hexadecimal ? "0x" : "0b"
      let result =
        (integer.isNegative ? localeMinusSign : "") + marker
        + integer.magnitudeDigits(radix: radix)
      try validateLength(result.count)
      return (result, false)
    case .fraction:
      guard case .rational(let rational) = value else {
        return (try localizeDecimal(canonical), isRounded)
      }
      let result = try joined(
        try canonicalInteger(rational.numerator), "/",
        try canonicalInteger(rational.denominator))
      try validateLength(result.count)
      return (result, false)
    }
  }

  /// Whether a canonical decimal is at least 1e21 or, not being zero, below
  /// 1e-6, where a power of ten reads better than a row of zeroes.
  static func isOutsideDigitRange(_ canonical: String) -> Bool {
    let unsigned = canonical.drop { $0 == "-" }
    let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts[0] == "0" else {
      return parts[0].count > 21
    }
    let fraction = parts.count == 2 ? parts[1] : ""
    guard let first = fraction.firstIndex(where: { $0 != "0" }) else {
      return false
    }
    return fraction.distance(from: fraction.startIndex, to: first) >= 6
  }

  /// `1234.5` as `1.2345e3`: the significant digits, a point where the locale
  /// puts one, and the power of ten that puts them back. Zero is written `0`,
  /// as no power of ten says more about it.
  private func scientific(_ canonical: String) throws -> String {
    let isNegative = canonical.first == "-"
    let unsigned = isNegative ? String(canonical.dropFirst()) : canonical
    let parts = unsigned.split(
      separator: ".",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    let whole = String(parts[0])
    let digits = whole + (parts.count == 2 ? String(parts[1]) : "")
    guard let first = digits.firstIndex(where: { $0 != "0" }) else {
      return localizeDigits("0")
    }

    let exponent = whole.count - digits.distance(from: digits.startIndex, to: first) - 1
    var mantissa = String(digits[first...])
    while mantissa.count > 1, mantissa.hasSuffix("0") {
      mantissa.removeLast()
    }

    var result = isNegative ? localeMinusSign : ""
    result += localizeDigits(String(mantissa.removeFirst()))
    if !mantissa.isEmpty {
      result += localeDecimalSeparator + localizeDigits(mantissa)
    }
    result += "e"
    result += exponent < 0 ? localeMinusSign : ""
    result += localizeDigits(String(abs(exponent)))
    try validateLength(result.count)
    return result
  }

  func localizeDecimal(_ canonical: String) throws -> String {
    let isNegative = canonical.first == "-"
    let unsigned = isNegative ? String(canonical.dropFirst()) : canonical
    let parts = unsigned.split(
      separator: ".",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    var result =
      (isNegative ? localeMinusSign : "")
      + localizeDigits(try group(String(parts[0])))
    if parts.count == 2 {
      result += localeDecimalSeparator
      result += localizeDigits(String(parts[1]))
    }
    return result
  }

  private func group(_ digits: String) throws -> String {
    guard
      display.groupsDigits,
      let separator = localeGroupingSeparator,
      localePrimaryGroupingSize > 0,
      digits.count
        >= localePrimaryGroupingSize + convention.minimumGroupingDigits
    else {
      return digits
    }

    let secondarySize =
      localeSecondaryGroupingSize > 0
      ? localeSecondaryGroupingSize
      : localePrimaryGroupingSize
    let separatorCount =
      (digits.count - localePrimaryGroupingSize - 1) / secondarySize + 1
    let (separatorCharacters, overflow) =
      separatorCount
      .multipliedReportingOverflow(by: separator.count)
    guard !overflow else {
      throw FormattingError.outputTooLong
    }
    try validateCombinedLength([digits.count, separatorCharacters])

    var groups: [Substring] = []
    groups.reserveCapacity(separatorCount + 1)
    let firstGroupSize =
      (digits.count - localePrimaryGroupingSize - 1) % secondarySize + 1
    var start = digits.startIndex
    var size = firstGroupSize
    var remaining = digits.count
    while remaining > 0 {
      let end = digits.index(start, offsetBy: size)
      groups.append(digits[start..<end])
      start = end
      remaining -= size
      size =
        remaining == localePrimaryGroupingSize
        ? localePrimaryGroupingSize
        : secondarySize
    }
    return groups.joined(separator: separator)
  }

  private func localizeDigits(_ value: String) -> String {
    let digits = localizedDigits
    return String(
      value.map { character in
        guard let ascii = character.asciiValue,
          (48...57).contains(ascii)
        else {
          return character
        }
        return digits[Int(ascii - 48)]
      }
    )
  }

  private var localizedDigits: [Character] {
    convention.digits
  }

  private func approximateDisplay(
    _ value: ApproximateValue
  ) throws -> String {
    let formatter = localeNumberFormatter
    let magnitude = abs(value.estimate)
    formatter.numberStyle =
      magnitude != 0 && (magnitude < 0.000_001 || magnitude >= 1e15)
      ? .scientific
      : .decimal
    formatter.usesGroupingSeparator = true
    formatter.usesSignificantDigits = true
    formatter.minimumSignificantDigits = 1
    formatter.maximumSignificantDigits = min(
      context.precision.significantDecimalDigits,
      value.knownSignificantDecimalDigits(for: value.estimate)
        ?? context.precision.significantDecimalDigits
    )
    formatter.roundingMode = context.precision.roundingRule.numberFormatterMode
    guard let result = formatter.string(from: NSNumber(value: value.estimate))
    else {
      throw FormattingError.outputTooLong
    }
    try validateLength(result.count)
    return result
  }

  private func joined(_ components: String...) throws -> String {
    try validateCombinedLength(components.map(\.count))
    return components.joined()
  }

  private func validateCombinedLength(_ components: [Int]) throws {
    var total = 0
    for component in components {
      let (next, overflow) = total.addingReportingOverflow(component)
      guard !overflow else {
        throw FormattingError.outputTooLong
      }
      total = next
    }
    try validateLength(total)
  }

  private func validateLength(_ length: Int) throws {
    guard length <= limits.maximumCharacters else {
      throw FormattingError.outputTooLong
    }
  }

  private var localeNumberFormatter: NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: context.localeIdentifier)
    formatter.numberStyle = .decimal
    return formatter
  }

  private var localeDecimalSeparator: String {
    convention.decimalSeparator
  }

  private var localeGroupingSeparator: String? {
    convention.groupingSeparator
  }

  private var localeMinusSign: String {
    convention.minusSign
  }

  private var localePrimaryGroupingSize: Int {
    convention.primaryGroupingSize
  }

  private var localeSecondaryGroupingSize: Int {
    display.groupsInLakhs ? 2 : convention.secondaryGroupingSize
  }
}

public struct ResultFormatter: Sendable {
  private let numericFormatter: NumericResultFormatter
  private let percentConvention: LocalePercentConvention
  private let limits: FormattingLimits
  private let locale: Locale
  private let display: DisplayOptions

  public init(
    context: EvaluationContext,
    limits: FormattingLimits = .default,
    display: DisplayOptions = .standard
  ) {
    self.display = display
    numericFormatter = NumericResultFormatter(
      context: context,
      limits: limits,
      display: display
    )
    percentConvention = LocalePercentConvention(
      localeIdentifier: context.localeIdentifier
    )
    self.limits = limits
    locale = Locale(identifier: context.localeIdentifier)
  }

  public func format(_ value: EngineValue) throws -> FormattedResult {
    switch value {
    case .number(let number):
      return try numericFormatter.format(number)
    case .percentage(let percentage):
      let points = try numericFormatter.format(percentage.points)
      let display = percentConvention.format(
        points.display,
        isNegative: percentage.points.isNegative,
        isApproximate: points.isApproximate || points.isRounded
      )
      let fullPrecision = points.fullPrecision + "%"
      guard
        display.count <= limits.maximumCharacters,
        fullPrecision.count <= limits.maximumCharacters
      else {
        throw FormattingError.outputTooLong
      }
      return FormattedResult(
        display: display,
        fullPrecision: fullPrecision,
        isApproximate: points.isApproximate,
        isRounded: points.isRounded
      )
    case .quantity(let quantity):
      return try appendUnit(
        try numericFormatter.format(quantity.magnitude),
        symbol: quantity.unit.symbol
      )
    case .date(let date):
      return try checked(
        display: temporalFormatter(date: .medium, time: .none, zone: utc).string(
          from: utcDate(date)),
        fullPrecision: String(format: "%04d-%02d-%02d", date.year, date.month, date.day)
      )
    case .time(let time):
      return try checked(
        display: temporalFormatter(
          date: .none, time: time.second == 0 ? .short : .medium, zone: utc
        )
        .string(
          from: Date(timeIntervalSinceReferenceDate: TimeInterval(time.secondsSinceMidnight))),
        fullPrecision: String(format: "%02d:%02d:%02d", time.hour, time.minute, time.second)
      )
    case .instant(let instant):
      let zone = TimeZone(identifier: instant.timeZoneIdentifier) ?? utc
      let hasSeconds =
        Calendar(identifier: .gregorian).dateComponents(in: zone, from: instant.date).second != 0
      let iso = ISO8601DateFormatter()
      iso.timeZone = zone
      iso.formatOptions = [.withInternetDateTime]
      return try checked(
        display: temporalFormatter(date: .medium, time: hasSeconds ? .medium : .short, zone: zone)
          .string(from: instant.date) + " " + instant.timeZoneIdentifier,
        fullPrecision: iso.string(from: instant.date) + "[\(instant.timeZoneIdentifier)]"
      )
    case .period(let period):
      return try checked(display: periodDisplay(period), fullPrecision: periodISO(period))
    case .money(let money):
      let exact = try numericFormatter.format(money.amount)
      let (display, isRounded) = try moneyDisplay(money)
      let isApproximate = exact.isApproximate || isRounded
      let perUnit = money.unit.map { "/" + parenthesizedIfCompound($0.symbol) } ?? ""
      let result = try checked(
        display: (isApproximate ? "≈ " : "") + display + perUnit,
        fullPrecision: exact.fullPrecision + " " + money.currency + perUnit
      )
      return FormattedResult(
        display: result.display, fullPrecision: result.fullPrecision, isApproximate: isApproximate)
    case .rate(let rate):
      let amount = try format(rate.amount)
      let displayDenominator = denominatorDisplay(rate.denominator)
      let canonicalDenominator = parenthesizedIfCompound(
        rate.denominator.symbol
      )
      return try appendSuffixes(
        amount,
        display: "/\(displayDenominator)",
        fullPrecision: "/\(canonicalDenominator)"
      )
    }
  }

  private var utc: TimeZone {
    TimeZone(identifier: "UTC")!
  }

  private func temporalFormatter(
    date: DateFormatter.Style,
    time: DateFormatter.Style,
    zone: TimeZone
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = zone
    formatter.dateStyle = date
    formatter.timeStyle = time
    return formatter
  }

  private func utcDate(_ date: DateValue) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day))
      ?? Date()
  }

  /// A period in years, months, and days, such as `1 year, 2 months, 3 days`.
  /// Days are formatted apart from months so they never become months.
  private func periodDisplay(_ period: CalendarPeriodValue) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    func format(_ components: DateComponents, units: NSCalendar.Unit) -> String? {
      let formatter = DateComponentsFormatter()
      formatter.calendar = calendar
      formatter.unitsStyle = .full
      formatter.allowedUnits = units
      formatter.zeroFormattingBehavior = .dropAll
      return formatter.string(from: components)
    }
    let months =
      period.months == 0
      ? nil
      : format(
        DateComponents(year: period.months / 12, month: period.months % 12), units: [.year, .month])
    let days =
      period.days == 0 && months != nil
      ? nil : format(DateComponents(day: period.days), units: .day)
    return [months, days].compactMap { $0 }.joined(separator: ", ")
  }

  /// The amount in the locale's currency style, rounded half away from zero
  /// to the currency's minor units, and whether rounding changed it.
  private func moneyDisplay(_ money: MoneyValue) throws -> (String, isRounded: Bool) {
    let digits = CurrencyCatalog.minorUnits[money.currency] ?? 2
    let plain: String
    let isRounded: Bool
    switch money.amount {
    case .approximate(let approximate):
      plain = String(format: "%.\(digits)f", approximate.estimate)
      isRounded = Double(plain) != approximate.estimate
    default:
      let (rounded, changed) = try money.amount.rounded(fractionDigits: digits)
      plain = try numericFormatter.canonicalDecimal(rounded)
      isRounded = changed
    }

    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .currency
    formatter.currencyCode = money.currency
    formatter.minimumFractionDigits = digits
    formatter.maximumFractionDigits = digits
    // The currency writes the decimals; the sheet still says how digits group.
    formatter.usesGroupingSeparator = display.groupsDigits
    if display.groupsInLakhs {
      formatter.secondaryGroupingSize = 2
    }
    guard
      plain.count <= Self.currencyDigitCapacity,
      let value = Decimal(string: plain),
      let text = formatter.string(from: NSDecimalNumber(decimal: value))
    else {
      // A wider amount than Foundation's decimal holds keeps every digit and
      // gives up only the locale's currency symbol.
      return (
        try numericFormatter.localizeDecimal(plain) + " " + money.currency,
        isRounded
      )
    }
    return (text, isRounded)
  }

  /// Foundation's `Decimal` holds 38 significant digits and silently drops
  /// the rest, so wider amounts do not go through it.
  private static let currencyDigitCapacity = 38

  /// ISO 8601 duration notation with signed components, such as `P1Y2M3D`.
  private func periodISO(_ period: CalendarPeriodValue) -> String {
    let parts = [(period.months / 12, "Y"), (period.months % 12, "M"), (period.days, "D")]
      .filter { $0.0 != 0 }
      .map { "\($0.0)\($0.1)" }
    return "P" + (parts.isEmpty ? "0D" : parts.joined())
  }

  private func checked(display: String, fullPrecision: String) throws -> FormattedResult {
    guard display.count <= limits.maximumCharacters, fullPrecision.count <= limits.maximumCharacters
    else {
      throw FormattingError.outputTooLong
    }
    return FormattedResult(display: display, fullPrecision: fullPrecision, isApproximate: false)
  }

  private func format(_ amount: RateAmount) throws -> FormattedResult {
    switch amount {
    case .number(let number):
      return try numericFormatter.format(number)
    case .percentage(let percentage):
      return try format(EngineValue.percentage(percentage))
    }
  }

  private func appendUnit(
    _ result: FormattedResult,
    symbol: String
  ) throws -> FormattedResult {
    try appendSuffix(result, suffix: " \(symbol)")
  }

  private func appendSuffix(
    _ result: FormattedResult,
    suffix: String
  ) throws -> FormattedResult {
    try appendSuffixes(result, display: suffix, fullPrecision: suffix)
  }

  private func appendSuffixes(
    _ result: FormattedResult,
    display displaySuffix: String,
    fullPrecision fullPrecisionSuffix: String
  ) throws -> FormattedResult {
    let display = result.display + displaySuffix
    let fullPrecision = result.fullPrecision + fullPrecisionSuffix
    guard
      display.count <= limits.maximumCharacters,
      fullPrecision.count <= limits.maximumCharacters
    else {
      throw FormattingError.outputTooLong
    }
    return FormattedResult(
      display: display,
      fullPrecision: fullPrecision,
      isApproximate: result.isApproximate,
      isRounded: result.isRounded
    )
  }

  private func denominatorDisplay(_ denominator: RateDenominator) -> String {
    switch denominator {
    case .unit(let unit):
      return parenthesizedIfCompound(unit.symbol)
    case .calendar(.month):
      return localizedRatePeriod("rate.period.month", fallback: "month")
    case .calendar(.quarter):
      return localizedRatePeriod("rate.period.quarter", fallback: "quarter")
    case .calendar(.year):
      return localizedRatePeriod("rate.period.year", fallback: "year")
    }
  }

  private func parenthesizedIfCompound(_ symbol: String) -> String {
    symbol.contains("/") || symbol.contains("·") ? "(\(symbol))" : symbol
  }

  private func localizedRatePeriod(
    _ key: String,
    fallback: String
  ) -> String {
    guard
      let language = locale.language.languageCode?.identifier,
      let path = FormattingResources.bundle?.path(
        forResource: language,
        ofType: "lproj"
      ),
      let localizedBundle = Bundle(path: path)
    else {
      return fallback
    }
    return localizedBundle.localizedString(
      forKey: key,
      value: fallback,
      table: nil
    )
  }
}

public struct DiagnosticFormatter: Sendable {
  private let locale: Locale

  public init(localeIdentifier: String) {
    locale = Locale(identifier: localeIdentifier)
  }

  public init(context: EvaluationContext) {
    self.init(localeIdentifier: context.localeIdentifier)
  }

  public func format(_ diagnostic: SyntaxDiagnostic) -> FormattedDiagnostic {
    return FormattedDiagnostic(
      code: diagnostic.code.rawValue,
      severity: diagnostic.severity,
      ranges: [diagnostic.range],
      message: message(for: diagnostic.code)
    )
  }

  public func format(_ error: EngineError) -> FormattedDiagnostic {
    FormattedDiagnostic(
      code: error.code.rawValue,
      severity: error.severity,
      ranges: error.ranges,
      message: message(for: error),
      fixIts: error.fixIts
    )
  }

  public func format(
    _ error: FormattingError,
    ranges: [SourceRange]
  ) -> FormattedDiagnostic {
    let message: String
    switch error {
    case .outputTooLong:
      message = localized(
        "error.formatting.outputTooLong",
        defaultValue: "The formatted result is too long to display."
      )
    case .internalFailure:
      message = localized(
        "error.formatting.internalFailure",
        defaultValue: "The result could not be formatted."
      )
    }
    return FormattedDiagnostic(
      code: error.code,
      severity: .error,
      ranges: ranges,
      message: message
    )
  }

  private func message(for code: SyntaxDiagnostic.Code) -> String {
    switch code {
    case .unexpectedCharacter:
      return localized(
        "syntax.unexpectedCharacter",
        defaultValue: "This character is not valid in an expression."
      )
    case .mixedDigitScripts:
      return localized(
        "syntax.mixedDigitScripts",
        defaultValue: "Use one digit script within each number."
      )
    case .missingRadixDigits:
      return localized(
        "syntax.missingRadixDigits",
        defaultValue: "Enter digits after the radix prefix."
      )
    case .invalidRadixDigit:
      return localized(
        "syntax.invalidRadixDigit",
        defaultValue: "This digit is not valid for the number's radix."
      )
    case .missingFractionDigits:
      return localized(
        "syntax.missingFractionDigits",
        defaultValue: "Enter digits after the decimal separator."
      )
    case .missingExponentDigits:
      return localized(
        "syntax.missingExponentDigits",
        defaultValue: "Enter digits in the exponent."
      )
    case .exponentOutOfRange:
      return localized(
        "syntax.exponentOutOfRange",
        defaultValue: "The exponent is too large."
      )
    case .expectedExpression:
      return localized(
        "syntax.expectedExpression",
        defaultValue: "Enter an expression here."
      )
    case .expectedPercentagePhrase:
      return localized(
        "syntax.expectedPercentagePhrase",
        defaultValue: "Complete the percentage phrase."
      )
    case .expectedConversionUnit:
      return localized(
        "syntax.expectedConversionUnit",
        defaultValue: "Enter a unit to convert to."
      )
    case .unknownUnit:
      return localized(
        "syntax.unknownUnit",
        defaultValue: "This unit is not recognized."
      )
    case .ambiguousSlashDate:
      return localized(
        "syntax.ambiguousSlashDate",
        defaultValue: "Write a date as 2026-09-16 or 16 Sep 2026, or put spaces around / to divide."
      )
    case .ambiguousCurrencySymbol:
      return localized(
        "syntax.ambiguousCurrencySymbol",
        defaultValue: "This symbol is used by several currencies. Write a code such as USD."
      )
    case .unknownTimeZone:
      return localized(
        "syntax.unknownTimeZone",
        defaultValue: "Enter a time zone such as Asia/Tokyo or a listed city."
      )
    case .invalidUnitExponent:
      return localized(
        "syntax.invalidUnitExponent",
        defaultValue: "Use a bounded signed integer unit exponent."
      )
    case .expectedUnitClosingParenthesis:
      return localized(
        "syntax.expectedUnitClosingParenthesis",
        defaultValue: "Add a closing parenthesis to the unit."
      )
    case .expectedClosingParenthesis:
      return localized(
        "syntax.expectedClosingParenthesis",
        defaultValue: "Add a closing parenthesis."
      )
    case .expectedArgumentSeparator:
      return localized(
        "syntax.expectedArgumentSeparator",
        defaultValue: "Separate function arguments."
      )
    case .unexpectedToken:
      return localized(
        "syntax.unexpectedToken",
        defaultValue: "This part of the expression is unexpected."
      )
    case .nonWordName:
      return localized(
        "syntax.nonWordName",
        defaultValue: "A name is words: `Groceries Costco`, or a label ending in a colon."
      )
    case .invalidVariableName:
      return localized(
        "syntax.invalidVariableName",
        defaultValue: "This word is already a unit, function, or keyword. Choose another name."
      )
    case .resourceLimitExceeded:
      return localized(
        "syntax.resourceLimitExceeded",
        defaultValue: "The expression is too complex."
      )
    }
  }

  private func message(for error: EngineError) -> String {
    switch error.code {
    case .zeroDenominator:
      return localized(
        "error.numeric.zeroDenominator",
        defaultValue: "A fraction denominator cannot be zero."
      )
    case .invalidIntegerLiteral:
      return localized(
        "error.numeric.invalidIntegerLiteral",
        defaultValue: "The integer is not valid."
      )
    case .integerLiteralTooLong:
      return localized(
        "error.numeric.integerLiteralTooLong",
        defaultValue: "The integer has too many digits."
      )
    case .invalidDecimalScale:
      return localized(
        "error.numeric.invalidDecimalScale",
        defaultValue: "The decimal scale is not valid."
      )
    case .nonFiniteApproximation:
      return localized(
        "error.numeric.nonFiniteApproximation",
        defaultValue: "The approximation is not finite."
      )
    case .invalidApproximationPrecision:
      return localized(
        "error.numeric.invalidApproximationPrecision",
        defaultValue: "The requested precision is not supported."
      )
    case .negativeApproximationErrorBound:
      return localized(
        "error.numeric.negativeApproximationErrorBound",
        defaultValue: "An approximation error bound cannot be negative."
      )
    case .divisionByZero:
      return localized(
        "error.evaluation.divisionByZero",
        defaultValue: "Cannot divide by zero."
      )
    case .invalidDomain where error.context == .unitPower:
      return localized(
        "error.evaluation.invalidDomain.unitPower",
        defaultValue: "A unit can only be raised to a whole number."
      )
    case .invalidDomain:
      return localized(
        "error.evaluation.invalidDomain",
        defaultValue: "This operation is not defined for the given value."
      )
    case .overflow:
      return localized(
        "error.evaluation.overflow",
        defaultValue: "The result is outside the supported range."
      )
    case .nonConvergence:
      return localized(
        "error.evaluation.nonConvergence",
        defaultValue: "The calculation did not converge."
      )
    case .unknownIdentifier:
      return localized(
        "error.evaluation.unknownIdentifier",
        defaultValue: "This identifier is not defined."
      )
    case .unavailableReference:
      if case .failedLine(let line) = error.context {
        return String(
          format: localized(
            "error.evaluation.unavailableReference.line",
            defaultValue: "Line %lld has an error, so this cannot use it."
          ),
          line
        )
      }
      if case .failedVariable(let name) = error.context {
        return String(
          format: localized(
            "error.evaluation.unavailableReference.variable",
            defaultValue: "%@ has an error, so this cannot use it."
          ),
          name
        )
      }
      return localized(
        "error.evaluation.unavailableReference",
        defaultValue: "This refers to a result that has an error."
      )
    case .invalidReference:
      return localized(
        "error.evaluation.invalidReference",
        defaultValue: "Refer to a result on a line above."
      )
    case .unknownFunction:
      return localized(
        "error.evaluation.unknownFunction",
        defaultValue: "This function is not defined."
      )
    case .unresolvedAssistantPrompt:
      return localized(
        "error.evaluation.unresolvedAssistantPrompt",
        defaultValue: "This needs an assistant. Turn one on under Ganit ▸ Assistant…."
      )
    case .unusableAssistantAnswer:
      return localized(
        "error.evaluation.unusableAssistantAnswer",
        defaultValue: "The assistant's answer could not be used as a value."
      )
    case .argumentCountMismatch:
      return localized(
        "error.evaluation.argumentCountMismatch",
        defaultValue: "The function received the wrong number of arguments."
      )
    case .typeMismatch:
      return localized(
        "error.evaluation.typeMismatch",
        defaultValue: "This operation cannot combine these value types."
      )
    case .incompatibleDimensions:
      return localized(
        "error.evaluation.incompatibleDimensions",
        defaultValue: "These quantities have incompatible dimensions."
      )
    case .invalidUnitDefinition:
      return localized(
        "error.evaluation.invalidUnitDefinition",
        defaultValue: "This unit definition is invalid."
      )
    case .affineUnitInCompound:
      return localized(
        "error.evaluation.affineUnitInCompound",
        defaultValue: "Affine units cannot be used in compound unit algebra."
      )
    case .invalidAbsoluteQuantityOperation:
      return localized(
        "error.evaluation.invalidAbsoluteQuantityOperation",
        defaultValue: "Absolute quantities cannot be used in this arithmetic operation."
      )
    case .incompatibleRatePeriods:
      return localized(
        "error.evaluation.incompatibleRatePeriods",
        defaultValue: "Calendar rate periods cannot be converted to fixed unit periods."
      )
    case .invalidDate:
      return localized(
        "error.evaluation.invalidDate",
        defaultValue: "This date does not exist."
      )
    case .invalidTime:
      return localized(
        "error.evaluation.invalidTime",
        defaultValue: "Times need a valid hour, minute, and whole seconds."
      )
    case .fractionalCalendarPeriod:
      return localized(
        "error.evaluation.fractionalCalendarPeriod",
        defaultValue: "Calendar periods need whole numbers."
      )
    case .dateOutOfRange:
      return localized(
        "error.evaluation.dateOutOfRange",
        defaultValue: "The date is outside the supported range."
      )
    case .nonexistentLocalTime:
      return localized(
        "error.evaluation.nonexistentLocalTime",
        defaultValue: "This time is skipped when clocks move forward in this time zone."
      )
    case .ambiguousLocalTime:
      return localized(
        "error.evaluation.ambiguousLocalTime",
        defaultValue: "This time happens twice when clocks move back. Add a UTC offset."
      )
    case .currencyRatesUnavailable:
      return localized(
        "error.evaluation.currencyRatesUnavailable",
        defaultValue:
          "Exchange rates have not been downloaded yet. Declare a rate such as 1 USD = 83 INR."
      )
    case .mixedCurrencies:
      return localized(
        "error.evaluation.mixedCurrencies",
        defaultValue: "These amounts are in different currencies. Convert one with in."
      )
    case .missingCurrencyRate:
      return localized(
        "error.evaluation.missingCurrencyRate",
        defaultValue: "No exchange rate is available for this currency."
      )
    case .invalidCurrencyRate:
      return localized(
        "error.evaluation.invalidCurrencyRate",
        defaultValue: "The exchange rate is not valid."
      )
    case .offsetMismatch:
      return localized(
        "error.evaluation.offsetMismatch",
        defaultValue: "This UTC offset is not used in the time zone at this time."
      )
    case .resourceLimitExceeded:
      return resourceLimitMessage(for: error.context)
    case .approximationOutOfRange:
      return localized(
        "error.evaluation.approximationOutOfRange",
        defaultValue: "This value cannot be approximated safely."
      )
    case .internalFailure:
      return localized(
        "error.evaluation.internalFailure",
        defaultValue: "The calculation could not be completed."
      )
    case .invalidEvaluationContext:
      return localized(
        "error.evaluation.invalidContext",
        defaultValue: "The calculation settings are not valid."
      )
    }
  }

  private func resourceLimitMessage(
    for context: EngineErrorContext
  ) -> String {
    guard case .resourceLimit(let resource) = context else {
      return localized(
        "error.evaluation.resourceLimitExceeded",
        defaultValue: "The calculation exceeds a resource limit."
      )
    }
    switch resource {
    case .operations:
      return localized(
        "error.evaluation.resourceLimit.operations",
        defaultValue: "The calculation has too many operations."
      )
    case .integerBits:
      return localized(
        "error.evaluation.resourceLimit.integerBits",
        defaultValue: "The exact integer result is too large."
      )
    case .decimalScale:
      return localized(
        "error.evaluation.resourceLimit.decimalScale",
        defaultValue: "The decimal scale is too large."
      )
    case .powerExponent:
      return localized(
        "error.evaluation.resourceLimit.powerExponent",
        defaultValue: "The power exponent is too large."
      )
    case .rootDegree:
      return localized(
        "error.evaluation.resourceLimit.rootDegree",
        defaultValue: "The root degree is too large."
      )
    case .functionArguments:
      return localized(
        "error.evaluation.resourceLimit.functionArguments",
        defaultValue: "The function has too many arguments."
      )
    case .dimensionExponent:
      return localized(
        "error.evaluation.resourceLimit.dimensionExponent",
        defaultValue: "The compound unit exponent is too large."
      )
    case .unitFactors:
      return localized(
        "error.evaluation.resourceLimit.unitFactors",
        defaultValue: "The compound unit has too many factors."
      )
    }
  }

  private func localized(
    _ key: StaticString,
    defaultValue: String.LocalizationValue
  ) -> String {
    String(
      localized: key,
      defaultValue: defaultValue,
      bundle: FormattingResources.bundle,
      locale: locale
    )
  }
}

private struct LocalePercentConvention: Sendable {
  let positivePrefix: String
  let positiveSuffix: String
  let negativePrefix: String
  let negativeSuffix: String
  let decimalNegativePrefix: String
  let decimalNegativeSuffix: String

  init(localeIdentifier: String) {
    let locale = Locale(identifier: localeIdentifier)
    let decimal = NumberFormatter()
    decimal.locale = locale
    decimal.numberStyle = .decimal
    decimal.usesGroupingSeparator = false
    let percent = NumberFormatter()
    percent.locale = locale
    percent.numberStyle = .percent
    percent.usesGroupingSeparator = false

    let number = decimal.string(from: NSNumber(value: 100)) ?? "100"
    let positive = percent.string(from: NSNumber(value: 1)) ?? (number + "%")
    let negative = percent.string(from: NSNumber(value: -1)) ?? ("-" + positive)
    let decimalNegative =
      decimal.string(from: NSNumber(value: -100)) ?? ("-" + number)

    (positivePrefix, positiveSuffix) = Self.affixes(
      surrounding: number,
      in: positive,
      fallbackSuffix: percent.percentSymbol ?? "%"
    )
    (negativePrefix, negativeSuffix) = Self.affixes(
      surrounding: number,
      in: negative,
      fallbackSuffix: percent.percentSymbol ?? "%"
    )
    (decimalNegativePrefix, decimalNegativeSuffix) = Self.affixes(
      surrounding: number,
      in: decimalNegative
    )
  }

  func format(
    _ numericDisplay: String,
    isNegative: Bool,
    isApproximate: Bool
  ) -> String {
    var unsigned = numericDisplay
    if isApproximate {
      unsigned.removeFirst(min(2, unsigned.count))
    }
    if isNegative {
      if unsigned.hasPrefix(decimalNegativePrefix) {
        unsigned.removeFirst(decimalNegativePrefix.count)
      }
      if unsigned.hasSuffix(decimalNegativeSuffix) {
        unsigned.removeLast(decimalNegativeSuffix.count)
      }
    }
    let prefix = isNegative ? negativePrefix : positivePrefix
    let suffix = isNegative ? negativeSuffix : positiveSuffix
    let localized = prefix + unsigned + suffix
    return isApproximate ? "≈ " + localized : localized
  }

  private static func affixes(
    surrounding number: String,
    in formatted: String,
    fallbackSuffix: String = ""
  ) -> (String, String) {
    guard let range = formatted.range(of: number) else {
      return ("", fallbackSuffix)
    }
    return (
      String(formatted[..<range.lowerBound]),
      String(formatted[range.upperBound...])
    )
  }
}

private struct LocaleNumberConvention: Sendable {
  let decimalSeparator: String
  let groupingSeparator: String?
  let minusSign: String
  let primaryGroupingSize: Int
  let secondaryGroupingSize: Int
  let minimumGroupingDigits: Int
  let digits: [Character]

  init(localeIdentifier: String) {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: localeIdentifier)
    formatter.numberStyle = .decimal
    decimalSeparator = formatter.decimalSeparator ?? "."
    let detectedGroupingSeparator = formatter.groupingSeparator
    groupingSeparator = detectedGroupingSeparator
    minusSign = formatter.minusSign ?? "-"
    let detectedPrimaryGroupingSize = formatter.groupingSize
    primaryGroupingSize = detectedPrimaryGroupingSize
    secondaryGroupingSize = formatter.secondaryGroupingSize
    if let detectedGroupingSeparator,
      detectedPrimaryGroupingSize > 0
    {
      minimumGroupingDigits =
        (1...4).first { extraDigits in
          let value = pow(
            10.0,
            Double(detectedPrimaryGroupingSize + extraDigits - 1)
          )
          return formatter.string(from: NSNumber(value: value))?
            .contains(detectedGroupingSeparator) == true
        } ?? 1
    } else {
      minimumGroupingDigits = 1
    }

    formatter.numberStyle = .none
    formatter.usesGroupingSeparator = false
    digits = (0...9).map { value in
      formatter.string(from: NSNumber(value: value))?.first
        ?? Character(String(value))
    }
  }
}

extension RoundingRule {
  fileprivate var numberFormatterMode: NumberFormatter.RoundingMode {
    switch self {
    case .toNearestOrEven:
      return .halfEven
    case .awayFromZero:
      return .up
    case .towardZero:
      return .down
    case .up:
      return .ceiling
    case .down:
      return .floor
    }
  }
}

extension ApproximateValue {
  fileprivate func knownSignificantDecimalDigits(for estimate: Double) -> Int? {
    switch precision {
    case .significantDecimalDigits(let digits),
      .requestedSignificantDecimalDigits(let digits):
      return digits
    case .absoluteErrorBound(let error):
      guard !error.coefficient.isZero, estimate != 0 else {
        return nil
      }
      let coefficient = error.coefficient.canonicalDigits
      let magnitude =
        coefficient.first == "-"
        ? coefficient.dropFirst()
        : coefficient[...]
      let isPowerOfTen =
        magnitude.first == "1"
        && magnitude.dropFirst().allSatisfy { $0 == "0" }
      let errorExponent =
        Double(magnitude.count - 1) - Double(error.scale)
        + (isPowerOfTen ? 0 : 1)
      let estimateExponent = floor(log10(abs(estimate)))
      let digits = estimateExponent - errorExponent + 1
      guard digits.isFinite else {
        return nil
      }
      if digits <= 1 {
        return 1
      }
      if digits >= Double(ApproximateValue.maximumSignificantDecimalDigits) {
        return ApproximateValue.maximumSignificantDecimalDigits
      }
      return Int(digits)
    case .unspecified:
      return nil
    }
  }
}
