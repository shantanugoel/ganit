import BigInt
import Foundation

struct NumericOperations {
  let context: EvaluationContext
  let limits: EvaluationLimits

  func applying(
    _ binaryOperator: BinaryOperator,
    left: NumericValue,
    right: NumericValue
  ) throws -> NumericValue {
    if binaryOperator == .power {
      return try power(left, right)
    }
    if case .approximate = left {
      return try approximate(binaryOperator, left, right)
    }
    if case .approximate = right {
      return try approximate(binaryOperator, left, right)
    }

    switch binaryOperator {
    case .add:
      return try add(left, right)
    case .subtract:
      return try subtract(left, right)
    case .multiply:
      return try multiply(left, right)
    case .divide:
      return try divide(left, right)
    case .power:
      return try power(left, right)
    }
  }

  func applying(
    _ unaryOperator: UnaryOperator,
    to value: NumericValue
  ) throws -> NumericValue {
    guard unaryOperator == .minus else {
      return value
    }
    switch value {
    case .integer(let integer):
      return try checkedInteger(-integer.storage)
    case .rational(let rational):
      return try fractionValue(
        Fraction(
          numerator: -rational.numerator.storage,
          denominator: rational.denominator.storage
        )
      )
    case .decimal(let decimal):
      return .decimal(
        try DecimalValue(
          coefficient: IntegerValue(storage: -decimal.coefficient.storage),
          scale: decimal.scale
        )
      )
    case .approximate(let approximate):
      return .approximate(
        try ApproximateValue(
          estimate: -approximate.estimate,
          source: .derivedArithmetic,
          precision: .unspecified
        )
      )
    }
  }

  func absoluteValue(_ value: NumericValue) throws -> NumericValue {
    switch value {
    case .integer(let integer):
      return try checkedInteger(BigInt(integer.storage.magnitude))
    case .rational(let rational):
      return try fractionValue(
        Fraction(
          numerator: BigInt(rational.numerator.storage.magnitude),
          denominator: rational.denominator.storage
        )
      )
    case .decimal(let decimal):
      return .decimal(
        try DecimalValue(
          coefficient: IntegerValue(
            storage: BigInt(decimal.coefficient.storage.magnitude)
          ),
          scale: decimal.scale
        )
      )
    case .approximate(let approximate):
      return .approximate(
        try ApproximateValue(
          estimate: Swift.abs(approximate.estimate),
          source: .derivedArithmetic,
          precision: approximate.precision
        )
      )
    }
  }

  func rounded(
    _ value: NumericValue,
    rule: FloatingPointRoundingRule
  ) throws -> NumericValue {
    if case .approximate(let approximate) = value {
      return .approximate(
        try ApproximateValue(
          estimate: approximate.estimate.rounded(rule),
          source: .explicitRounding,
          precision: .unspecified
        )
      )
    }

    let fraction = try exactFraction(value)
    return try checkedInteger(
      try roundedQuotient(fraction.numerator, fraction.denominator, rule: rule)
    )
  }

  /// Indices of `values` in ascending numeric order.
  func ascendingIndices(_ values: [NumericValue]) throws -> [Int] {
    if values.contains(where: {
      if case .approximate = $0 { return true }
      return false
    }) {
      let estimates = try values.map(approximateEstimate)
      return values.indices.sorted { estimates[$0] < estimates[$1] }
    }
    return try values.indices.sorted { try compare(values[$0], values[$1]) < 0 }
  }

  func extremum(
    _ values: [NumericValue],
    selectMinimum: Bool
  ) throws -> NumericValue {
    if values.contains(where: {
      if case .approximate = $0 { return true }
      return false
    }) {
      var selected = try approximateEstimate(values[0])
      for value in values.dropFirst() {
        let candidate = try approximateEstimate(value)
        if selectMinimum ? candidate < selected : candidate > selected {
          selected = candidate
        }
      }
      return .approximate(
        try ApproximateValue(
          estimate: selected,
          source: .derivedArithmetic,
          precision: .unspecified
        )
      )
    }

    var selected = values[0]
    for candidate in values.dropFirst() {
      let comparison = try compare(candidate, selected)
      if selectMinimum ? comparison < 0 : comparison > 0 {
        selected = candidate
      }
    }
    return selected
  }

  func root(_ value: NumericValue, degree: NumericValue) throws -> NumericValue {
    let degreeFraction: Fraction
    do {
      degreeFraction = try exactFraction(degree)
    } catch let error as EngineError {
      throw EngineError(
        code: error.code,
        severity: error.severity,
        context: .rootDegree
      )
    }
    guard
      degreeFraction.denominator == 1,
      degreeFraction.numerator > 0,
      degreeFraction.numerator <= BigInt(limits.maximumRootDegree)
    else {
      if degreeFraction.numerator > BigInt(limits.maximumRootDegree) {
        throw limitError(.rootDegree)
      }
      throw EngineError(code: .invalidDomain, context: .rootDegree)
    }
    let integerDegree = Int(degreeFraction.numerator)

    if case .approximate(let approximate) = value {
      if approximate.estimate < 0, integerDegree.isMultiple(of: 2) {
        throw EngineError(code: .invalidDomain, context: .rootRadicand)
      }
      return try approximateRoot(value, degree: integerDegree)
    }

    let fraction = try exactFraction(value)
    if fraction.numerator < 0, integerDegree.isMultiple(of: 2) {
      throw EngineError(code: .invalidDomain, context: .rootRadicand)
    }

    let numeratorRoot = integerRoot(
      fraction.numerator.magnitude,
      degree: integerDegree
    )
    let denominatorRoot = integerRoot(
      fraction.denominator.magnitude,
      degree: integerDegree
    )
    if numeratorRoot.exact, denominatorRoot.exact {
      let signedNumerator =
        fraction.numerator < 0
        ? -BigInt(numeratorRoot.value)
        : BigInt(numeratorRoot.value)
      return try fractionValue(
        Fraction(
          numerator: signedNumerator,
          denominator: BigInt(denominatorRoot.value)
        )
      )
    }
    return try approximateRoot(value, degree: integerDegree)
  }

  func transcendental(
    _ function: BuiltInFunction,
    value: NumericValue
  ) throws -> NumericValue {
    let result: Double

    switch function {
    case .sine:
      result = Foundation.sin(try trigonometricInput(value))
    case .cosine:
      result = Foundation.cos(try trigonometricInput(value))
    case .tangent:
      result = Foundation.tan(try trigonometricInput(value, forTangent: true))
    case .arcSine:
      try validateInverseTrigonometricDomain(value)
      let input = try approximateEstimate(value)
      guard (-1...1).contains(input) else {
        throw EngineError(code: .invalidDomain)
      }
      result = angleResult(Foundation.asin(input))
    case .arcCosine:
      try validateInverseTrigonometricDomain(value)
      let input = try approximateEstimate(value)
      guard (-1...1).contains(input) else {
        throw EngineError(code: .invalidDomain)
      }
      result = angleResult(Foundation.acos(input))
    case .arcTangent:
      result = angleResult(try arcTangent(value))
    case .naturalLogarithm:
      result = try logarithm(of: value)
    case .commonLogarithm, .commonLogarithmExplicit:
      result = try logarithm(of: value) / Foundation.log(10)
    case .exponential:
      result = Foundation.exp(try approximateEstimate(value))
    default:
      throw EngineError(code: .invalidDomain)
    }

    guard result.isFinite else {
      throw EngineError(code: .approximationOutOfRange)
    }
    if function == .exponential, result == 0 {
      throw EngineError(code: .approximationOutOfRange)
    }
    return .approximate(
      try ApproximateValue(
        estimate: result,
        source: .transcendentalFunction,
        precision: .requestedSignificantDecimalDigits(
          context.precision.transcendentalSignificantDigits
        )
      )
    )
  }

  private func logarithm(of value: NumericValue) throws -> Double {
    let representation = logarithmicRepresentation(value)
    guard !representation.isZero, !representation.isNegative else {
      throw EngineError(code: .invalidDomain)
    }
    return representation.logarithmOfMagnitude
  }

  private func arcTangent(_ value: NumericValue) throws -> Double {
    let representation = logarithmicRepresentation(value)
    guard !representation.isZero else {
      return 0
    }
    let magnitude: Double
    if representation.logarithmOfMagnitude > 0 {
      let reciprocal = Foundation.exp(
        -representation.logarithmOfMagnitude
      )
      magnitude = .pi / 2 - Foundation.atan(reciprocal)
    } else {
      let input = Foundation.exp(representation.logarithmOfMagnitude)
      guard input != 0 else {
        throw EngineError(code: .approximationOutOfRange)
      }
      magnitude = Foundation.atan(input)
    }
    return representation.isNegative ? -magnitude : magnitude
  }

  private func validateInverseTrigonometricDomain(
    _ value: NumericValue
  ) throws {
    guard case .approximate = value else {
      guard
        try compare(value, .integer(IntegerValue(-1))) >= 0,
        try compare(value, .integer(IntegerValue(1))) <= 0
      else {
        throw EngineError(code: .invalidDomain)
      }
      return
    }
  }

  private func trigonometricInput(
    _ value: NumericValue,
    forTangent: Bool = false
  ) throws -> Double {
    switch context.angleMode {
    case .radians:
      let input = try approximateEstimate(value)
      guard Swift.abs(input) <= 1_000_000_000_000 else {
        throw EngineError(code: .approximationOutOfRange)
      }
      return input

    case .degrees:
      if case .approximate = value {
        let input = try approximateEstimate(value)
        guard Swift.abs(input) <= 1_000_000_000_000 else {
          throw EngineError(code: .approximationOutOfRange)
        }
        let reduced = input.truncatingRemainder(dividingBy: 360)
        if forTangent, Swift.abs(reduced) == 90 || Swift.abs(reduced) == 270 {
          throw EngineError(code: .invalidDomain)
        }
        return reduced * .pi / 180
      }

      let fraction = try exactFraction(value)
      try preflightMultiplication(fraction.denominator, 360)
      let modulus = fraction.denominator * 360
      let reduced = Fraction(
        numerator: fraction.numerator % modulus,
        denominator: fraction.denominator
      )
      if forTangent {
        let absoluteNumerator = reduced.numerator.magnitude
        let denominator = reduced.denominator.magnitude
        try preflightMultiplication(BigInt(denominator), 270)
        if absoluteNumerator == denominator * 90
          || absoluteNumerator == denominator * 270
        {
          throw EngineError(code: .invalidDomain)
        }
      }
      return try approximateEstimate(try fractionValue(reduced)) * .pi / 180
    }
  }

  private func angleResult(_ radians: Double) -> Double {
    context.angleMode == .degrees
      ? radians * 180 / .pi
      : radians
  }

  private func add(
    _ left: NumericValue,
    _ right: NumericValue
  ) throws -> NumericValue {
    if hasRational(left, right) {
      let lhs = try exactFraction(left)
      let rhs = try exactFraction(right)
      return try addFractions(lhs, rhs, subtracting: false)
    }
    if hasDecimal(left, right) {
      return try addDecimals(left, right, subtracting: false)
    }
    return try checkedInteger(
      try integer(left).storage + integer(right).storage
    )
  }

  private func subtract(
    _ left: NumericValue,
    _ right: NumericValue
  ) throws -> NumericValue {
    if hasRational(left, right) {
      let lhs = try exactFraction(left)
      let rhs = try exactFraction(right)
      return try addFractions(lhs, rhs, subtracting: true)
    }
    if hasDecimal(left, right) {
      return try addDecimals(left, right, subtracting: true)
    }
    return try checkedInteger(
      try integer(left).storage - integer(right).storage
    )
  }

  private func multiply(
    _ left: NumericValue,
    _ right: NumericValue
  ) throws -> NumericValue {
    if hasRational(left, right) {
      let lhs = try exactFraction(left)
      let rhs = try exactFraction(right)
      return try multiplyFractions(lhs, rhs)
    }
    if hasDecimal(left, right) {
      let lhs = try decimal(left)
      let rhs = try decimal(right)
      let scale = try checkedScale(lhs.scale, plus: rhs.scale)
      try preflightMultiplication(
        lhs.coefficient.storage,
        rhs.coefficient.storage
      )
      let coefficient = lhs.coefficient.storage * rhs.coefficient.storage
      try validateInteger(coefficient)
      return .decimal(
        try DecimalValue(
          coefficient: IntegerValue(storage: coefficient),
          scale: scale
        )
      )
    }
    let lhs = try integer(left).storage
    let rhs = try integer(right).storage
    try preflightMultiplication(lhs, rhs)
    return try checkedInteger(lhs * rhs)
  }

  private func divide(
    _ left: NumericValue,
    _ right: NumericValue
  ) throws -> NumericValue {
    let rhs = try exactFraction(right)
    guard !rhs.numerator.isZero else {
      throw EngineError(code: .divisionByZero)
    }
    let lhs = try exactFraction(left)
    let result = try multipliedFraction(
      lhs,
      Fraction(numerator: rhs.denominator, denominator: rhs.numerator)
    )

    if hasDecimal(left, right), let decimal = try exactDecimal(result) {
      return .decimal(decimal)
    }
    return try fractionValue(result)
  }

  private func power(
    _ base: NumericValue,
    _ exponent: NumericValue
  ) throws -> NumericValue {
    if case .approximate(let approximateExponent) = exponent {
      if try approximateEstimate(base) < 0 {
        throw EngineError(code: .invalidDomain)
      }
      guard
        Swift.abs(approximateExponent.estimate)
          <= Double(limits.maximumPowerExponent)
      else {
        throw limitError(.powerExponent)
      }
      return try approximate(.power, base, exponent)
    }

    let exponentFraction = try exactFraction(exponent)
    guard exponentFraction.denominator == 1 else {
      guard
        exponentFraction.denominator
          <= BigInt(limits.maximumRootDegree)
      else {
        throw limitError(.rootDegree)
      }
      guard
        exponentFraction.numerator.magnitude
          <= BigUInt(limits.maximumPowerExponent)
      else {
        throw limitError(.powerExponent)
      }
      let rooted = try root(
        base,
        degree: .integer(
          IntegerValue(storage: exponentFraction.denominator)
        )
      )
      return try power(
        rooted,
        .integer(IntegerValue(storage: exponentFraction.numerator))
      )
    }
    guard
      exponentFraction.numerator.magnitude
        <= BigUInt(limits.maximumPowerExponent)
    else {
      throw limitError(.powerExponent)
    }
    let exponentValue = Int(exponentFraction.numerator)
    if case .approximate = base {
      return try approximate(.power, base, exponent)
    }
    if exponentValue == 0 {
      guard !(try exactFraction(base).numerator.isZero) else {
        throw EngineError(code: .invalidDomain)
      }
      return .integer(IntegerValue(1))
    }
    if exponentValue < 0, try exactFraction(base).numerator.isZero {
      throw EngineError(code: .divisionByZero)
    }

    if case .decimal(let decimal) = base, exponentValue > 0 {
      let scale = try checkedScale(decimal.scale, multipliedBy: exponentValue)
      try preflightPower(decimal.coefficient.storage, exponent: exponentValue)
      let coefficient = decimal.coefficient.storage.power(exponentValue)
      try validateInteger(coefficient)
      return .decimal(
        try DecimalValue(
          coefficient: IntegerValue(storage: coefficient),
          scale: scale
        )
      )
    }
    if case .integer(let integer) = base, exponentValue > 0 {
      try preflightPower(integer.storage, exponent: exponentValue)
      return try checkedInteger(integer.storage.power(exponentValue))
    }

    let fraction = try exactFraction(base)
    let magnitude = Swift.abs(exponentValue)
    try preflightPower(fraction.numerator, exponent: magnitude)
    try preflightPower(fraction.denominator, exponent: magnitude)
    let powered = Fraction(
      numerator: fraction.numerator.power(magnitude),
      denominator: fraction.denominator.power(magnitude)
    )
    if exponentValue < 0 {
      let reciprocal = Fraction(
        numerator: powered.denominator,
        denominator: powered.numerator
      )
      if case .decimal = base, let decimal = try exactDecimal(reciprocal) {
        return .decimal(decimal)
      }
      return try fractionValue(reciprocal)
    }
    return try fractionValue(powered)
  }

  private func approximate(
    _ binaryOperator: BinaryOperator,
    _ left: NumericValue,
    _ right: NumericValue
  ) throws -> NumericValue {
    let lhs = try approximateEstimate(left)
    let rhs = try approximateEstimate(right)
    let result: Double
    switch binaryOperator {
    case .add:
      result = lhs + rhs
    case .subtract:
      result = lhs - rhs
    case .multiply:
      result = lhs * rhs
    case .divide:
      guard rhs != 0 else {
        throw EngineError(code: .divisionByZero)
      }
      result = lhs / rhs
    case .power:
      if lhs == 0, rhs == 0 {
        throw EngineError(code: .invalidDomain)
      }
      if lhs == 0, rhs < 0 {
        throw EngineError(code: .divisionByZero)
      }
      if lhs < 0, rhs.rounded(.towardZero) != rhs {
        throw EngineError(code: .invalidDomain)
      }
      result = Foundation.pow(lhs, rhs)
    }
    return try approximateResult(
      result,
      inputs: [lhs, rhs],
      rejectUnexpectedZero: binaryOperator != .add
        && binaryOperator != .subtract
    )
  }

  private func approximateRoot(
    _ value: NumericValue,
    degree: Int
  ) throws -> NumericValue {
    let representation = logarithmicRepresentation(value)
    guard !representation.isZero else {
      return .approximate(
        try ApproximateValue(
          estimate: 0,
          source: .derivedArithmetic,
          precision: .requestedSignificantDecimalDigits(
            context.precision.transcendentalSignificantDigits
          )
        )
      )
    }
    let result = try finiteDouble(
      logarithmOfMagnitude: representation.logarithmOfMagnitude
        / Double(degree),
      negative: representation.isNegative
    )
    return .approximate(
      try ApproximateValue(
        estimate: result,
        source: .derivedArithmetic,
        precision: .requestedSignificantDecimalDigits(
          context.precision.transcendentalSignificantDigits
        )
      )
    )
  }

  private func approximateResult(
    _ result: Double,
    inputs: [Double],
    rejectUnexpectedZero: Bool
  ) throws -> NumericValue {
    guard result.isFinite else {
      throw EngineError(code: .approximationOutOfRange)
    }
    if rejectUnexpectedZero,
      result == 0,
      inputs.allSatisfy({ $0 != 0 })
    {
      throw EngineError(code: .approximationOutOfRange)
    }
    return .approximate(
      try ApproximateValue(
        estimate: result,
        source: .derivedArithmetic,
        precision: .unspecified
      )
    )
  }

  private func approximateEstimate(_ value: NumericValue) throws -> Double {
    let representation = logarithmicRepresentation(value)
    guard !representation.isZero else {
      return 0
    }
    return try finiteDouble(
      logarithmOfMagnitude: representation.logarithmOfMagnitude,
      negative: representation.isNegative
    )
  }

  private func logarithmicRepresentation(
    _ value: NumericValue
  ) -> (
    logarithmOfMagnitude: Double,
    isNegative: Bool,
    isZero: Bool
  ) {
    switch value {
    case .integer(let integer):
      return logarithmicRepresentation(
        numerator: integer.storage,
        denominator: 1
      )
    case .rational(let rational):
      return logarithmicRepresentation(
        numerator: rational.numerator.storage,
        denominator: rational.denominator.storage
      )
    case .decimal(let decimal):
      guard !decimal.coefficient.isZero else {
        return (0, false, true)
      }
      let components = floatingComponents(
        decimal.coefficient.storage.magnitude
      )
      return (
        Foundation.log(components.significand)
          + Double(components.binaryExponent) * Foundation.log(2)
          - Double(decimal.scale) * Foundation.log(10),
        decimal.coefficient.isNegative,
        false
      )
    case .approximate(let approximate):
      guard approximate.estimate != 0 else {
        return (0, false, true)
      }
      return (
        Foundation.log(Swift.abs(approximate.estimate)),
        approximate.estimate < 0,
        false
      )
    }
  }

  private func logarithmicRepresentation(
    numerator: BigInt,
    denominator: BigInt
  ) -> (
    logarithmOfMagnitude: Double,
    isNegative: Bool,
    isZero: Bool
  ) {
    guard !numerator.isZero else {
      return (0, false, true)
    }
    let numeratorComponents = floatingComponents(numerator.magnitude)
    let denominatorComponents = floatingComponents(denominator.magnitude)
    return (
      Foundation.log(numeratorComponents.significand)
        - Foundation.log(denominatorComponents.significand)
        + Double(
          numeratorComponents.binaryExponent
            - denominatorComponents.binaryExponent
        ) * Foundation.log(2),
      numerator < 0,
      false
    )
  }

  private func floatingComponents(
    _ value: BigUInt
  ) -> (significand: Double, binaryExponent: Int) {
    let shift = max(0, value.bitWidth - 53)
    return (Double(value >> shift), shift)
  }

  private func finiteDouble(
    logarithmOfMagnitude: Double,
    negative: Bool
  ) throws -> Double {
    let magnitude = Foundation.exp(logarithmOfMagnitude)
    guard magnitude.isFinite, magnitude != 0 else {
      throw EngineError(code: .approximationOutOfRange)
    }
    return negative ? -magnitude : magnitude
  }

  private func addFractions(
    _ left: Fraction,
    _ right: Fraction,
    subtracting: Bool
  ) throws -> NumericValue {
    let commonDivisor = left.denominator.greatestCommonDivisor(
      with: right.denominator
    )
    let leftMultiplier = right.denominator / commonDivisor
    let rightMultiplier = left.denominator / commonDivisor
    try preflightMultiplication(left.numerator, leftMultiplier)
    try preflightMultiplication(right.numerator, rightMultiplier)
    try preflightMultiplication(left.denominator, leftMultiplier)
    let leftProduct = left.numerator * leftMultiplier
    let rightProduct = right.numerator * rightMultiplier
    let numerator =
      subtracting
      ? leftProduct - rightProduct
      : leftProduct + rightProduct
    try validateInteger(numerator)
    return try fractionValue(
      Fraction(
        numerator: numerator,
        denominator: left.denominator * leftMultiplier
      )
    )
  }

  private func multiplyFractions(
    _ left: Fraction,
    _ right: Fraction
  ) throws -> NumericValue {
    try fractionValue(multipliedFraction(left, right))
  }

  private func multipliedFraction(
    _ left: Fraction,
    _ right: Fraction
  ) throws -> Fraction {
    let leftCancellation = left.numerator.greatestCommonDivisor(
      with: right.denominator
    )
    let rightCancellation = right.numerator.greatestCommonDivisor(
      with: left.denominator
    )
    let leftNumerator = left.numerator / leftCancellation
    let rightNumerator = right.numerator / rightCancellation
    let leftDenominator = left.denominator / rightCancellation
    let rightDenominator = right.denominator / leftCancellation
    try preflightMultiplication(leftNumerator, rightNumerator)
    try preflightMultiplication(leftDenominator, rightDenominator)
    return Fraction(
      numerator: leftNumerator * rightNumerator,
      denominator: leftDenominator * rightDenominator
    )
  }

  private func addDecimals(
    _ left: NumericValue,
    _ right: NumericValue,
    subtracting: Bool
  ) throws -> NumericValue {
    let lhs = try decimal(left)
    let rhs = try decimal(right)
    let scale = max(lhs.scale, rhs.scale)
    try validateScale(scale)
    let lhsMultiplier = try powerOfTen(scale - lhs.scale)
    let rhsMultiplier = try powerOfTen(scale - rhs.scale)
    try preflightMultiplication(lhs.coefficient.storage, lhsMultiplier)
    try preflightMultiplication(rhs.coefficient.storage, rhsMultiplier)
    let lhsCoefficient = lhs.coefficient.storage * lhsMultiplier
    let rhsCoefficient = rhs.coefficient.storage * rhsMultiplier
    let coefficient =
      subtracting
      ? lhsCoefficient - rhsCoefficient
      : lhsCoefficient + rhsCoefficient
    try validateInteger(coefficient)
    return .decimal(
      try DecimalValue(
        coefficient: IntegerValue(storage: coefficient),
        scale: scale
      )
    )
  }

  private func exactDecimal(_ fraction: Fraction) throws -> DecimalValue? {
    var denominator = fraction.denominator.magnitude
    let twos = denominator.trailingZeroBitCount
    var fives = 0
    denominator >>= twos
    while denominator % 5 == 0 {
      denominator /= 5
      fives += 1
    }
    guard denominator == 1 else {
      return nil
    }

    let scale = max(twos, fives)
    try validateScale(scale)
    var coefficient = fraction.numerator
    if twos < scale {
      let multiplier = BigInt(2).power(scale - twos)
      try preflightMultiplication(coefficient, multiplier)
      coefficient *= multiplier
    }
    if fives < scale {
      let multiplier = BigInt(5).power(scale - fives)
      try preflightMultiplication(coefficient, multiplier)
      coefficient *= multiplier
    }
    try validateInteger(coefficient)
    return try DecimalValue(
      coefficient: IntegerValue(storage: coefficient),
      scale: scale
    )
  }

  private func compare(
    _ left: NumericValue,
    _ right: NumericValue
  ) throws -> Int {
    let lhs = try exactFraction(left)
    let rhs = try exactFraction(right)
    try preflightMultiplication(lhs.numerator, rhs.denominator)
    try preflightMultiplication(rhs.numerator, lhs.denominator)
    let leftProduct = lhs.numerator * rhs.denominator
    let rightProduct = rhs.numerator * lhs.denominator
    return leftProduct < rightProduct ? -1 : (leftProduct > rightProduct ? 1 : 0)
  }

  /// The value as an `Int` when it is exactly a whole number in range.
  func exactInteger(_ value: NumericValue) -> Int? {
    guard let fraction = try? exactFraction(value), fraction.denominator == 1 else {
      return nil
    }
    return Int(exactly: fraction.numerator)
  }

  /// The value as a `Double`, rounding exact values to the nearest one.
  func double(_ value: NumericValue) throws -> Double {
    if case .approximate = value {
      return try approximateEstimate(value)
    }
    let fraction = try exactFraction(value)
    let result = Double(fraction.numerator) / Double(fraction.denominator)
    guard result.isFinite else {
      throw EngineError(code: .approximationOutOfRange)
    }
    return result
  }

  private func exactFraction(_ value: NumericValue) throws -> Fraction {
    switch value {
    case .integer(let integer):
      return Fraction(numerator: integer.storage, denominator: 1)
    case .rational(let rational):
      return Fraction(
        numerator: rational.numerator.storage,
        denominator: rational.denominator.storage
      )
    case .decimal(let decimal):
      try validateScale(decimal.scale)
      if decimal.scale >= 0 {
        return Fraction(
          numerator: decimal.coefficient.storage,
          denominator: try powerOfTen(decimal.scale)
        )
      }
      let multiplier = try powerOfTen(-decimal.scale)
      try preflightMultiplication(decimal.coefficient.storage, multiplier)
      return Fraction(
        numerator: decimal.coefficient.storage * multiplier,
        denominator: 1
      )
    case .approximate:
      throw EngineError(code: .invalidDomain)
    }
  }

  private func decimal(_ value: NumericValue) throws -> DecimalValue {
    switch value {
    case .decimal(let decimal):
      try validateScale(decimal.scale)
      return decimal
    case .integer(let integer):
      return try DecimalValue(coefficient: integer, scale: 0)
    default:
      throw EngineError(code: .invalidDomain)
    }
  }

  private func integer(_ value: NumericValue) throws -> IntegerValue {
    guard case .integer(let integer) = value else {
      throw EngineError(code: .invalidDomain)
    }
    return integer
  }

  private func fractionValue(_ fraction: Fraction) throws -> NumericValue {
    try validateInteger(fraction.numerator)
    try validateInteger(fraction.denominator)
    if fraction.denominator == 1 {
      return .integer(IntegerValue(storage: fraction.numerator))
    }
    return .rational(
      try RationalValue(
        numerator: IntegerValue(storage: fraction.numerator),
        denominator: IntegerValue(storage: fraction.denominator)
      )
    )
  }

  private func checkedInteger(_ value: BigInt) throws -> NumericValue {
    try validateInteger(value)
    return .integer(IntegerValue(storage: value))
  }

  private func validateInteger(_ value: BigInt) throws {
    guard value.magnitude.bitWidth <= limits.maximumIntegerBits else {
      throw limitError(.integerBits)
    }
  }

  private func validateScale(_ scale: Int) throws {
    guard
      scale != .min,
      Swift.abs(scale) <= limits.maximumDecimalScaleMagnitude
    else {
      throw limitError(.decimalScale)
    }
  }

  private func checkedScale(_ left: Int, plus right: Int) throws -> Int {
    let (result, overflow) = left.addingReportingOverflow(right)
    guard !overflow else {
      throw limitError(.decimalScale)
    }
    try validateScale(result)
    return result
  }

  private func checkedScale(_ scale: Int, multipliedBy value: Int) throws -> Int {
    let (result, overflow) = scale.multipliedReportingOverflow(by: value)
    guard !overflow else {
      throw limitError(.decimalScale)
    }
    try validateScale(result)
    return result
  }

  private func powerOfTen(_ exponent: Int) throws -> BigInt {
    try validateScale(exponent)
    guard
      exponent >= 0,
      exponent == 0
        || exponent <= (limits.maximumIntegerBits - 1) / 3
    else {
      throw limitError(.integerBits)
    }
    let result = BigInt(10).power(exponent)
    try validateInteger(result)
    return result
  }

  private func preflightMultiplication(_ left: BigInt, _ right: BigInt) throws {
    let leftBits = left.magnitude.bitWidth
    let rightBits = right.magnitude.bitWidth
    guard !left.isZero, !right.isZero else {
      return
    }
    let (sum, overflow) = leftBits.addingReportingOverflow(rightBits)
    guard !overflow, sum - 1 <= limits.maximumIntegerBits else {
      throw limitError(.integerBits)
    }
  }

  private func preflightPower(_ base: BigInt, exponent: Int) throws {
    guard exponent >= 0 else {
      throw EngineError(code: .invalidDomain)
    }
    if base.magnitude <= 1 {
      return
    }
    guard exponent > 0 else {
      return
    }
    let minimumBitsPerFactor = base.magnitude.bitWidth - 1
    guard
      minimumBitsPerFactor
        <= (limits.maximumIntegerBits - 1) / exponent
    else {
      throw limitError(.integerBits)
    }
  }

  private func hasDecimal(_ left: NumericValue, _ right: NumericValue) -> Bool {
    if case .decimal = left { return true }
    if case .decimal = right { return true }
    return false
  }

  private func hasRational(_ left: NumericValue, _ right: NumericValue) -> Bool {
    if case .rational = left { return true }
    if case .rational = right { return true }
    return false
  }

  private func integerRoot(
    _ value: BigUInt,
    degree: Int
  ) -> (value: BigUInt, exact: Bool) {
    if value <= 1 || degree == 1 {
      return (value, true)
    }
    var low = BigUInt(0)
    let rootBitWidth = (value.bitWidth - 1) / degree + 1
    var high = BigUInt(1) << (rootBitWidth + 1)
    while low + 1 < high {
      let midpoint = (low + high) >> 1
      let powered = midpoint.power(degree)
      if powered <= value {
        low = midpoint
      } else {
        high = midpoint
      }
    }
    return (low, low.power(degree) == value)
  }

  private func limitError(_ resource: EvaluationResource) -> EngineError {
    EngineError(
      code: .resourceLimitExceeded,
      context: .resourceLimit(resource)
    )
  }
}

private struct Fraction {
  let numerator: BigInt
  let denominator: BigInt

  init(numerator: BigInt, denominator: BigInt) {
    precondition(!denominator.isZero)
    var numerator = numerator
    var denominator = denominator
    if denominator < 0 {
      numerator = -numerator
      denominator = -denominator
    }
    let divisor = numerator.greatestCommonDivisor(with: denominator)
    self.numerator = numerator / divisor
    self.denominator = denominator / divisor
  }
}
