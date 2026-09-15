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

  public init(
    display: String,
    fullPrecision: String,
    isApproximate: Bool
  ) {
    self.display = display
    self.fullPrecision = fullPrecision
    self.isApproximate = isApproximate
  }
}

public struct NumericResultFormatter: Sendable {
  private let context: EvaluationContext
  private let limits: FormattingLimits
  private let convention: LocaleNumberConvention

  public init(
    context: EvaluationContext,
    limits: FormattingLimits = .default
  ) {
    self.context = context
    self.limits = limits
    convention = LocaleNumberConvention(
      localeIdentifier: context.localeIdentifier
    )
  }

  public func format(_ value: NumericValue) throws -> FormattedResult {
    switch value {
    case .integer(let integer):
      let canonical = try canonicalInteger(integer)
      return try exactResult(
        display: try localizeInteger(canonical),
        fullPrecision: canonical
      )

    case .rational(let rational):
      let numerator = try canonicalInteger(rational.numerator)
      let denominator = try canonicalInteger(rational.denominator)
      let canonical = try joined(numerator, "/", denominator)
      let display = try joined(
        try localizeInteger(numerator),
        "/",
        try localizeInteger(denominator)
      )
      return try exactResult(display: display, fullPrecision: canonical)

    case .decimal(let decimal):
      let canonical = try canonicalDecimal(decimal)
      return try exactResult(
        display: try localizeDecimal(canonical),
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
    display: String,
    fullPrecision: String
  ) throws -> FormattedResult {
    try validateLength(display.count)
    try validateLength(fullPrecision.count)
    return FormattedResult(
      display: display,
      fullPrecision: fullPrecision,
      isApproximate: false
    )
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

  private func canonicalDecimal(_ value: DecimalValue) throws -> String {
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

  private func localizeInteger(_ canonical: String) throws -> String {
    let isNegative = canonical.first == "-"
    let magnitude = isNegative ? String(canonical.dropFirst()) : canonical
    let grouped = try group(magnitude)
    return (isNegative ? localeMinusSign : "") + localizeDigits(grouped)
  }

  private func localizeDecimal(_ canonical: String) throws -> String {
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
    convention.secondaryGroupingSize
  }
}

public struct ResultFormatter: Sendable {
  private let numericFormatter: NumericResultFormatter
  private let percentConvention: LocalePercentConvention
  private let limits: FormattingLimits
  private let locale: Locale

  public init(
    context: EvaluationContext,
    limits: FormattingLimits = .default
  ) {
    numericFormatter = NumericResultFormatter(context: context, limits: limits)
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
        isApproximate: points.isApproximate
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
        isApproximate: points.isApproximate
      )
    case .quantity(let quantity):
      return try appendUnit(
        try numericFormatter.format(quantity.magnitude),
        symbol: quantity.unit.symbol
      )
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
      isApproximate: result.isApproximate
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
      let path = Bundle.module.path(
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
    case .unknownFunction:
      return localized(
        "error.evaluation.unknownFunction",
        defaultValue: "This function is not defined."
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
      bundle: .module,
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

extension NumericValue {
  fileprivate var isNegative: Bool {
    switch self {
    case .integer(let integer):
      return integer.isNegative
    case .rational(let rational):
      return rational.numerator.isNegative
    case .decimal(let decimal):
      return decimal.coefficient.isNegative
    case .approximate(let approximate):
      return approximate.estimate < 0
    }
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
