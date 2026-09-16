import Foundation

public struct Evaluator: Sendable {
  private let context: EvaluationContext
  private let limits: EvaluationLimits
  private let variables: [String: EngineValue?]
  private let lines: LineOutcomes
  private let manualRates: [CurrencyPair: NumericValue]

  public init(
    context: EvaluationContext,
    limits: EvaluationLimits = .default
  ) {
    self.init(
      context: context,
      limits: limits,
      variables: [:],
      lines: LineOutcomes()
    )
  }

  /// `variables` maps declared names to their values, or to `nil` when the
  /// declaration failed. `lines` holds the results of lines above, and
  /// `manualRates` the exchange rates declared above.
  init(
    context: EvaluationContext,
    limits: EvaluationLimits,
    variables: [String: EngineValue?],
    lines: LineOutcomes,
    manualRates: [CurrencyPair: NumericValue] = [:]
  ) {
    self.context = context
    self.limits = limits
    self.variables = variables
    self.lines = lines
    self.manualRates = manualRates
  }

  public func evaluate(_ expression: Expression) throws -> EngineValue {
    try evaluateTracing(expression).result.get()
  }

  /// The aggregate of these values, computed as a `total`, `average`, or
  /// `median` line computes it, for a caller that picked the values itself,
  /// such as a selection in the editor.
  public func aggregating(_ aggregate: Aggregate, of values: [EngineValue]) throws -> EngineValue {
    try EvaluationWorker(
      context: context,
      limits: limits,
      variables: variables,
      lines: lines,
      manualRates: manualRates
    ).evaluate(aggregate, of: values)
  }

  /// The result and what evaluation read besides its inputs.
  func evaluateTracing(_ expression: Expression) -> (
    result: Result<EngineValue, any Error>, trace: EvaluationTrace
  ) {
    var worker = EvaluationWorker(
      context: context,
      limits: limits,
      variables: variables,
      lines: lines,
      manualRates: manualRates
    )
    let result = Result { try worker.evaluate(expression) }
    return (result, worker.trace)
  }
}

/// What an evaluation read from its context: the clock, and exchange rates.
struct EvaluationTrace: Sendable {
  var clock: ClockResolution?
  var rateUses: Set<CurrencyRateUse> = []
  /// The finance functions a result used, whose assumptions it is shown with.
  var financeUses: Set<FinanceFunction> = []
}

/// How finely a result depends on the evaluation clock: a result that read
/// `today` can change only at midnight, and one that read `now` every second.
enum ClockResolution: Comparable, Sendable {
  case day
  case second
}

private struct EvaluationWorker {
  let context: EvaluationContext
  let limits: EvaluationLimits
  let operations: NumericOperations
  let unitAlgebra: UnitAlgebra
  let temporal: TemporalArithmetic
  let money: MoneyArithmetic
  let variables: [String: EngineValue?]
  let lines: LineOutcomes
  var visitedOperations = 0
  private(set) var trace = EvaluationTrace()

  init(
    context: EvaluationContext,
    limits: EvaluationLimits,
    variables: [String: EngineValue?],
    lines: LineOutcomes,
    manualRates: [CurrencyPair: NumericValue]
  ) {
    self.context = context
    self.limits = limits
    self.variables = variables
    self.lines = lines
    operations = NumericOperations(context: context, limits: limits)
    money = MoneyArithmetic(
      operations: operations, rates: context.currencyRates, manualRates: manualRates)
    unitAlgebra = UnitAlgebra(context: context, limits: limits)
    temporal = TemporalArithmetic(
      context: context, operations: operations, unitAlgebra: unitAlgebra)
  }

  // Evaluation recurses once per AST level. The dispatcher stays small and
  // each case lives in a non-inlined method, so a level's stack frame holds
  // only that case's values and deep expressions fit secondary-thread stacks.
  mutating func evaluate(_ expression: Expression) throws -> EngineValue {
    try visit(expression.range)

    do {
      switch expression {
      case .literal(let literal, let range):
        return .number(try evaluate(literal, range: range))
      case .identifier(let name, let range):
        return try evaluateIdentifier(name, range: range)
      case .prefix(let unaryOperator, let operand, let operatorRange, _):
        return try evaluatePrefix(unaryOperator, operand, operatorRange: operatorRange)
      case .infix(let left, let binaryOperator, let right, let operatorRange, _):
        return try evaluateInfix(left, binaryOperator, right, operatorRange: operatorRange)
      case .call(let name, let nameRange, let arguments, _):
        return try evaluateCall(name: name, nameRange: nameRange, arguments: arguments)
      case .assistantPrompt(_, let prompt, let nameRange, _):
        return try evaluateAssistantPrompt(prompt, nameRange: nameRange)
      case .percentage(let points, _, _):
        return try evaluatePercentage(points)
      case .percentageOperation(let percentageOperator, let left, let right, let operatorRange, _):
        return try evaluatePercentageOperation(
          percentageOperator,
          left,
          right,
          operatorRange: operatorRange
        )
      case .quantity(let magnitude, let unitSyntax, _):
        return try evaluateQuantity(magnitude, unitSyntax)
      case .period(let count, let unit, _):
        return try evaluatePeriod(count, unit)
      case .temporal(let literal, let range):
        return try evaluateTemporal(literal, at: range)
      case .relative(let offset, let isPast, _):
        return try evaluateRelative(offset, isPast: isPast)
      case .money(let amount, let currency, _):
        return try evaluateMoney(amount, currency)
      case .currencyConversion(let value, let currency, _):
        return try evaluateCurrencyConversion(value, currency)
      case .zoneConversion(let value, let zone, _):
        return try evaluateZoneConversion(value, zone)
      case .conversion(let valueExpression, let targetSyntax, _, _):
        return try evaluateConversion(valueExpression, to: targetSyntax)
      case .grouped(let nested, _):
        return try evaluate(nested)
      case .reference(let reference, _):
        return try evaluateReference(reference)
      }
    } catch let error as EngineError where error.ranges.isEmpty {
      throw error.located(at: expression.range)
    }
  }

  @inline(never)
  private func evaluateIdentifier(_ name: String, range: SourceRange) throws -> EngineValue {
    if let variable = variables[name] {
      guard let value = variable else {
        throw EngineError(
          code: .unavailableReference, ranges: [range], context: .failedVariable(name))
      }
      return value
    }
    let estimate: Double
    switch name {
    case "π", "pi":
      estimate = .pi
    case "e":
      estimate = Foundation.exp(1)
    default:
      throw EngineError(code: .unknownIdentifier, ranges: [range])
    }
    return .number(
      .approximate(
        try ApproximateValue(
          estimate: estimate,
          source: .mathematicalConstant,
          precision: .requestedSignificantDecimalDigits(
            context.precision.transcendentalSignificantDigits
          )
        )
      ))
  }

  @inline(never)
  private mutating func evaluatePrefix(
    _ unaryOperator: UnaryOperator,
    _ operand: Expression,
    operatorRange: SourceRange
  ) throws -> EngineValue {
    let value = try evaluate(operand)
    return try located(at: operatorRange) {
      try apply(unaryOperator, to: value)
    }
  }

  @inline(never)
  private mutating func evaluateInfix(
    _ left: Expression,
    _ binaryOperator: BinaryOperator,
    _ right: Expression,
    operatorRange: SourceRange
  ) throws -> EngineValue {
    let lhs = try evaluate(left)
    let rhs = try inCurrency(of: lhs, try evaluate(right), for: binaryOperator, at: right.range)
    let errorRange =
      binaryOperator == .divide || binaryOperator == .power
      ? right.range
      : operatorRange
    return try located(at: errorRange) {
      try apply(binaryOperator, left: lhs, right: rhs)
    }
  }

  /// `€40 + $10` adds the dollars in euros, at the rates `in` uses, and
  /// records that it used them.
  @inline(never)
  private mutating func inCurrency(
    of left: EngineValue, _ right: EngineValue, for binaryOperator: BinaryOperator,
    at range: SourceRange
  ) throws -> EngineValue {
    guard binaryOperator == .add || binaryOperator == .subtract,
      case .money(let lhs) = left, case .money(let rhs) = right,
      lhs.currency != rhs.currency, lhs.unit == rhs.unit
    else {
      return right
    }
    let (converted, use) = try located(at: range) {
      try money.converted(rhs, to: lhs.currency)
    }
    if let use {
      trace.rateUses.insert(use)
    }
    return .money(converted)
  }

  @inline(never)
  private mutating func evaluatePercentage(_ points: Expression) throws -> EngineValue {
    let value = try evaluate(points)
    return .percentage(
      PercentageValue(points: try requireNumber(value, at: points.range))
    )
  }

  @inline(never)
  private mutating func evaluatePercentageOperation(
    _ percentageOperator: PercentageOperator,
    _ left: Expression,
    _ right: Expression,
    operatorRange: SourceRange
  ) throws -> EngineValue {
    let lhs = try evaluate(left)
    let rhs = try evaluate(right)
    return try located(at: operatorRange) {
      try apply(
        percentageOperator,
        left: lhs,
        leftRange: left.range,
        right: rhs,
        rightRange: right.range
      )
    }
  }

  @inline(never)
  private mutating func evaluateQuantity(
    _ magnitude: Expression,
    _ unitSyntax: UnitSyntax
  ) throws -> EngineValue {
    let value = try evaluate(magnitude)
    let number = try requireNumber(value, at: magnitude.range)
    let unit = try located(at: unitSyntax.range) {
      try evaluate(unitSyntax)
    }
    return .quantity(QuantityValue(magnitude: number, unit: unit))
  }

  @inline(never)
  private mutating func evaluatePeriod(
    _ countExpression: Expression,
    _ unit: CalendarPeriodUnit
  ) throws -> EngineValue {
    let number = try requireNumber(try evaluate(countExpression), at: countExpression.range)
    guard let count = operations.exactInteger(number) else {
      throw EngineError(code: .fractionalCalendarPeriod, ranges: [countExpression.range])
    }
    guard let period = unit.period(count: count) else {
      throw EngineError(code: .dateOutOfRange, ranges: [countExpression.range])
    }
    return .period(period)
  }

  @inline(never)
  private mutating func evaluateMoney(_ amount: Expression, _ currency: String) throws
    -> EngineValue
  {
    .money(
      MoneyValue(amount: try requireNumber(evaluate(amount), at: amount.range), currency: currency))
  }

  @inline(never)
  private mutating func evaluateCurrencyConversion(
    _ valueExpression: Expression, _ currency: String
  )
    throws -> EngineValue
  {
    let value = try evaluate(valueExpression)
    guard case .money(let amount) = value else {
      throw typeMismatch(expected: .money, actual: value.kind, range: valueExpression.range)
    }
    let (converted, use) = try money.converted(amount, to: currency)
    if let use {
      trace.rateUses.insert(use)
    }
    return .money(converted)
  }

  @inline(never)
  private mutating func evaluateZoneConversion(_ value: Expression, _ zone: String) throws
    -> EngineValue
  {
    var evaluated = try evaluate(value)
    // `3:00 pm in Tokyo` is that time today here, shown there.
    if case .time(let time) = evaluated {
      readClock(.day)
      evaluated = .instant(try temporal.today(at: time, range: value.range))
    }
    return try temporal.converted(evaluated, toZone: zone)
  }

  @inline(never)
  private mutating func evaluateTemporal(_ literal: TemporalLiteral, at range: SourceRange) throws
    -> EngineValue
  {
    switch literal {
    case .now:
      readClock(.second)
    case .relativeDay, .weekday, .date(year: nil, _, _):
      readClock(.day)
    case .date, .time, .dateTime:
      break
    }
    return try temporal.value(of: literal, at: range)
  }

  private mutating func readClock(_ resolution: ClockResolution) {
    trace.clock = max(trace.clock ?? resolution, resolution)
  }

  @inline(never)
  private mutating func evaluateRelative(_ offset: Expression, isPast: Bool) throws -> EngineValue {
    let value = try evaluate(offset)
    let start: EngineValue
    switch value {
    case .period:
      readClock(.day)
      start = .date(try temporal.today())
    case .quantity:
      readClock(.second)
      start = .instant(temporal.now)
    default:
      throw typeMismatch(expected: .period, actual: value.kind, range: offset.range)
    }
    return try located(at: offset.range) {
      try temporal.apply(isPast ? .subtract : .add, left: start, right: value)!
    }
  }

  @inline(never)
  private mutating func evaluateConversion(
    _ valueExpression: Expression,
    to targetSyntax: UnitSyntax
  ) throws -> EngineValue {
    let value = try evaluate(valueExpression)
    guard case .quantity(var quantity) = value else {
      throw typeMismatch(
        expected: .quantity,
        actual: value.kind,
        range: valueExpression.range
      )
    }
    let target = try located(at: targetSyntax.range) {
      try evaluate(targetSyntax)
    }
    // A reciprocal unit reads the other way up: `35 mpg in L/100 km`.
    if quantity.unit.dimension != target.dimension, quantity.kind == .relative,
      try quantity.unit.dimension.multiplied(by: target.dimension) == .dimensionless
    {
      quantity = QuantityValue(
        magnitude: try operations.applying(
          .divide, left: .integer(IntegerValue(1)), right: quantity.magnitude),
        unit: try unitAlgebra.raised(quantity.unit, to: -1))
    }
    return .quantity(
      try located(at: targetSyntax.range) {
        try unitAlgebra.converted(quantity, to: target)
      }
    )
  }

  @inline(never)
  private func evaluateReference(_ reference: LineReference) throws -> EngineValue {
    guard case .aggregate(let aggregate) = reference else {
      return try lines.value(of: reference)
    }
    return try evaluate(aggregate, of: lines.values(for: aggregate))
  }

  private func apply(
    _ unaryOperator: UnaryOperator,
    to value: EngineValue
  ) throws -> EngineValue {
    switch value {
    case .number(let number):
      return .number(try operations.applying(unaryOperator, to: number))
    case .percentage(let percentage):
      return .percentage(
        PercentageValue(
          points: try operations.applying(
            unaryOperator,
            to: percentage.points
          )
        )
      )
    case .quantity(let quantity):
      return .quantity(
        QuantityValue(
          magnitude: try operations.applying(
            unaryOperator,
            to: quantity.magnitude
          ),
          unit: quantity.unit,
          kind: quantity.kind
        )
      )
    case .period(let period):
      return .period(try temporal.negated(period))
    case .money(let money):
      return .money(
        MoneyValue(
          amount: try operations.applying(unaryOperator, to: money.amount),
          currency: money.currency, unit: money.unit))
    case .rate, .date, .time, .instant:
      throw typeMismatch(expected: .number, actual: value.kind)
    }
  }

  private func apply(
    _ binaryOperator: BinaryOperator,
    left: EngineValue,
    right: EngineValue
  ) throws -> EngineValue {
    if let result = try temporal.apply(binaryOperator, left: left, right: right) {
      return result
    }
    if let result = try money.apply(
      binaryOperator, left: left, right: right, unitAlgebra: unitAlgebra)
    {
      return result
    }
    switch (left, right) {
    case (.number(let lhs), .number(let rhs)):
      return .number(
        try operations.applying(binaryOperator, left: lhs, right: rhs)
      )

    case (.number(let base), .percentage(let percentage)):
      let rate = try percentageRate(percentage)
      switch binaryOperator {
      case .add, .subtract:
        let change = try operations.applying(
          .multiply,
          left: base,
          right: rate
        )
        return .number(
          try operations.applying(
            binaryOperator,
            left: base,
            right: change
          )
        )
      case .multiply, .divide:
        return .number(
          try operations.applying(binaryOperator, left: base, right: rate)
        )
      case .power:
        throw typeMismatch(expected: .number, actual: .percentage)
      }

    case (.percentage(let percentage), .number(let number)):
      switch binaryOperator {
      case .multiply:
        return .number(
          try operations.applying(
            .multiply,
            left: try percentageRate(percentage),
            right: number
          )
        )
      case .divide:
        return .percentage(
          PercentageValue(
            points: try operations.applying(
              .divide,
              left: percentage.points,
              right: number
            )
          )
        )
      case .add, .subtract, .power:
        throw typeMismatch(expected: .percentage, actual: .number)
      }

    case (.percentage(let lhs), .percentage(let rhs)):
      switch binaryOperator {
      case .add, .subtract:
        return .percentage(
          PercentageValue(
            points: try operations.applying(
              binaryOperator,
              left: lhs.points,
              right: rhs.points
            )
          )
        )
      case .multiply, .divide:
        return .number(
          try operations.applying(
            binaryOperator,
            left: try percentageRate(lhs),
            right: try percentageRate(rhs)
          )
        )
      case .power:
        throw typeMismatch(expected: .number, actual: .percentage)
      }

    case (.quantity(let quantity), .percentage):
      guard quantity.kind == .relative else {
        throw EngineError(code: .invalidAbsoluteQuantityOperation)
      }
      return try quantityResult(
        apply(binaryOperator, left: .number(quantity.magnitude), right: right),
        quantity.unit
      )

    case (.quantity(let lhs), .quantity(let rhs)):
      switch binaryOperator {
      case .add:
        return .quantity(try unitAlgebra.adding(lhs, rhs))
      case .subtract:
        return .quantity(try unitAlgebra.subtracting(lhs, rhs))
      case .multiply:
        return try simplified(unitAlgebra.multiplying(lhs, rhs))
      case .divide:
        return try simplified(unitAlgebra.dividing(lhs, rhs))
      case .power:
        throw typeMismatch(expected: .number, actual: .quantity)
      }

    case (.quantity(let quantity), .number(let scalar)):
      switch binaryOperator {
      case .multiply, .divide:
        guard quantity.kind == .relative else {
          throw EngineError(code: .invalidAbsoluteQuantityOperation)
        }
        return .quantity(
          QuantityValue(
            magnitude: try operations.applying(
              binaryOperator,
              left: quantity.magnitude,
              right: scalar
            ),
            unit: quantity.unit,
            kind: .relative
          )
        )
      case .power:
        guard quantity.kind == .relative else {
          throw EngineError(code: .invalidAbsoluteQuantityOperation)
        }
        let exponent = try integerExponent(scalar)
        return try simplified(
          QuantityValue(
            magnitude: try operations.applying(
              .power,
              left: quantity.magnitude,
              right: scalar
            ),
            unit: try unitAlgebra.raised(quantity.unit, to: exponent),
            kind: .relative
          )
        )
      case .add, .subtract:
        throw typeMismatch(expected: .quantity, actual: .number)
      }

    case (.number(let scalar), .quantity(let quantity)):
      switch binaryOperator {
      case .multiply:
        guard quantity.kind == .relative else {
          throw EngineError(code: .invalidAbsoluteQuantityOperation)
        }
        return .quantity(
          QuantityValue(
            magnitude: try operations.applying(
              .multiply,
              left: scalar,
              right: quantity.magnitude
            ),
            unit: quantity.unit,
            kind: .relative
          )
        )
      case .divide:
        guard quantity.kind == .relative else {
          throw EngineError(code: .invalidAbsoluteQuantityOperation)
        }
        return .quantity(
          QuantityValue(
            magnitude: try operations.applying(
              .divide,
              left: scalar,
              right: quantity.magnitude
            ),
            unit: try unitAlgebra.raised(quantity.unit, to: -1),
            kind: .relative
          )
        )
      case .add, .subtract, .power:
        throw typeMismatch(expected: .number, actual: .quantity)
      }

    default:
      let actual = left.kind == .number ? right.kind : left.kind
      throw typeMismatch(expected: .number, actual: actual)
    }
  }

  private func evaluate(_ syntax: UnitSyntax) throws -> UnitExpression {
    switch syntax {
    case .named(let entry, let prefix, _):
      let definition =
        try prefix.map {
          try unitAlgebra.applying($0.prefix, to: entry.definition)
        } ?? entry.definition
      return try unitAlgebra.unit(definition)
    case .multiplied(let left, let right, _):
      return try unitAlgebra.multiplied(
        evaluate(left),
        by: evaluate(right)
      )
    case .divided(let left, let right, _):
      return try unitAlgebra.divided(
        evaluate(left),
        by: evaluate(right)
      )
    case .raised(let unit, let exponent, _):
      return try unitAlgebra.raised(evaluate(unit), to: exponent)
    case .counted(let count, let unit, _):
      guard case .ratio(let ratio) = try evaluate(unit) else {
        throw EngineError(code: .affineUnitInCompound)
      }
      let symbol = "\(count) \(ratio.symbol)"
      return try unitAlgebra.unit(
        UnitDefinition(
          canonicalIdentifier: symbol, symbol: symbol, dimension: ratio.dimension,
          transform: .ratio(
            scale: try operations.applying(
              .multiply, left: ratio.scaleToCanonical, right: .integer(IntegerValue(count))))))
    }
  }

  func evaluate(
    _ aggregate: Aggregate,
    of values: [EngineValue]
  ) throws -> EngineValue {
    let count = EngineValue.number(.integer(IntegerValue(values.count)))
    guard aggregate != .count else {
      return count
    }
    guard let first = values.first else {
      guard aggregate == .sum || aggregate == .subtotal else {
        throw EngineError(code: .invalidReference)
      }
      return .number(.integer(IntegerValue(0)))
    }
    if let mismatch = values.first(where: { $0.kind != first.kind }) {
      throw typeMismatch(expected: first.kind, actual: mismatch.kind)
    }

    switch aggregate {
    case .sum, .subtotal, .count:
      return try values.dropFirst().reduce(first) {
        try apply(.add, left: $0, right: $1)
      }
    case .average:
      return try apply(
        .divide,
        left: evaluate(.sum, of: values),
        right: count
      )
    case .median:
      let keys = try values.map { value -> NumericValue in
        switch (value, first) {
        case (.number(let number), _):
          return number
        case (.percentage(let percentage), _):
          return percentage.points
        case (.quantity(let quantity), .quantity(let reference)):
          return try unitAlgebra.converted(quantity, to: reference.unit).magnitude
        case (.money(let amount), .money(let reference)):
          guard amount.currency == reference.currency else {
            throw EngineError(code: .mixedCurrencies)
          }
          return amount.amount
        default:
          throw typeMismatch(expected: .number, actual: value.kind)
        }
      }
      let order = try operations.ascendingIndices(keys)
      let middle = values[order[order.count / 2]]
      guard order.count.isMultiple(of: 2) else {
        return middle
      }
      return try apply(
        .divide,
        left: apply(.add, left: values[order[order.count / 2 - 1]], right: middle),
        right: .number(.integer(IntegerValue(2)))
      )
    }
  }

  /// A quantity whose dimensions cancel, such as `km/m`, is a plain number
  /// in canonical scale.
  private func simplified(_ quantity: QuantityValue) throws -> EngineValue {
    guard quantity.unit.dimension == .dimensionless, case .ratio(let unit) = quantity.unit
    else {
      return .quantity(quantity)
    }
    return .number(
      try operations.applying(
        .multiply,
        left: quantity.magnitude,
        right: unit.scaleToCanonical
      )
    )
  }

  private func integerExponent(_ value: NumericValue) throws -> Int {
    guard case .integer(let integer) = value else {
      throw EngineError(code: .invalidDomain, context: .unitPower)
    }
    guard let exponent = Int(integer.canonicalDigits),
      exponent.magnitude <= Dimension.maximumExponentMagnitude
    else {
      throw EngineError(
        code: .resourceLimitExceeded,
        context: .resourceLimit(.dimensionExponent)
      )
    }
    return exponent
  }

  private func apply(
    _ percentageOperator: PercentageOperator,
    left: EngineValue,
    leftRange: SourceRange,
    right: EngineValue,
    rightRange: SourceRange
  ) throws -> EngineValue {
    // Percentages of money apply to the amount and keep the currency.
    switch (percentageOperator, left, right) {
    case (.of, _, .money(let money)), (.off, _, .money(let money)), (.on, _, .money(let money)):
      return try moneyResult(
        apply(
          percentageOperator, left: left, leftRange: leftRange, right: .number(money.amount),
          rightRange: rightRange), money)
    case (.reverseOff, .money(let money), _), (.reverseOn, .money(let money), _):
      return try moneyResult(
        apply(
          percentageOperator, left: .number(money.amount), leftRange: leftRange, right: right,
          rightRange: rightRange), money)
    // Percentages of a quantity scale its magnitude and keep its unit, for
    // quantities that count. A tenth of 20 °C is a point on no scale.
    case (.of, _, .quantity(let quantity)), (.off, _, .quantity(let quantity)),
      (.on, _, .quantity(let quantity)):
      guard quantity.kind == .relative else {
        throw EngineError(
          code: .invalidAbsoluteQuantityOperation, ranges: [rightRange])
      }
      return try quantityResult(
        apply(
          percentageOperator, left: left, leftRange: leftRange,
          right: .number(quantity.magnitude), rightRange: rightRange), quantity.unit)
    case (.reverseOff, .quantity(let quantity), _), (.reverseOn, .quantity(let quantity), _):
      guard quantity.kind == .relative else {
        throw EngineError(
          code: .invalidAbsoluteQuantityOperation, ranges: [leftRange])
      }
      return try quantityResult(
        apply(
          percentageOperator, left: .number(quantity.magnitude), leftRange: leftRange,
          right: right, rightRange: rightRange), quantity.unit)
    case (.ratio, .money(let lhs), .money(let rhs)), (.change, .money(let lhs), .money(let rhs)):
      guard lhs.currency == rhs.currency else {
        throw EngineError(code: .mixedCurrencies)
      }
      return try apply(
        percentageOperator, left: .number(lhs.amount), leftRange: leftRange,
        right: .number(rhs.amount), rightRange: rightRange)
    default:
      break
    }
    switch percentageOperator {
    case .of, .off, .on:
      let percentage = try requirePercentage(left, at: leftRange)
      let base = try requireNumber(right, at: rightRange)
      let rate = try percentageRate(percentage)
      let change = try operations.applying(.multiply, left: base, right: rate)
      switch percentageOperator {
      case .of:
        return .number(change)
      case .off:
        return .number(
          try operations.applying(.subtract, left: base, right: change)
        )
      case .on:
        return .number(
          try operations.applying(.add, left: base, right: change)
        )
      default:
        preconditionFailure("Handled percentage operator changed")
      }

    case .ratio:
      let part = try requireNumber(left, at: leftRange)
      let whole = try requireNumber(right, at: rightRange)
      let ratio = try located(at: rightRange) {
        try operations.applying(.divide, left: part, right: whole)
      }
      return .percentage(
        PercentageValue(
          points: try operations.applying(
            .multiply,
            left: ratio,
            right: .integer(IntegerValue(100))
          )
        )
      )

    case .change:
      let oldValue = try requireNumber(left, at: leftRange)
      let newValue = try requireNumber(right, at: rightRange)
      let difference = try operations.applying(
        .subtract,
        left: newValue,
        right: oldValue
      )
      let ratio = try located(at: leftRange) {
        try operations.applying(
          .divide,
          left: difference,
          right: oldValue
        )
      }
      return .percentage(
        PercentageValue(
          points: try operations.applying(
            .multiply,
            left: ratio,
            right: .integer(IntegerValue(100))
          )
        )
      )

    case .reverseOff, .reverseOn:
      let result = try requireNumber(left, at: leftRange)
      let percentage = try requirePercentage(right, at: rightRange)
      let rate = try percentageRate(percentage)
      let factor = try operations.applying(
        percentageOperator == .reverseOff ? .subtract : .add,
        left: .integer(IntegerValue(1)),
        right: rate
      )
      return .number(
        try located(at: rightRange) {
          try operations.applying(.divide, left: result, right: factor)
        }
      )
    }
  }

  private func moneyResult(_ value: EngineValue, _ money: MoneyValue) throws -> EngineValue {
    guard case .number(let amount) = value else {
      throw typeMismatch(expected: .number, actual: value.kind)
    }
    return .money(MoneyValue(amount: amount, currency: money.currency, unit: money.unit))
  }

  private func quantityResult(
    _ value: EngineValue, _ unit: UnitExpression
  ) throws -> EngineValue {
    guard case .number(let magnitude) = value else {
      throw typeMismatch(expected: .number, actual: value.kind)
    }
    return .quantity(
      QuantityValue(magnitude: magnitude, unit: unit, kind: .relative)
    )
  }

  private func percentageRate(
    _ percentage: PercentageValue
  ) throws -> NumericValue {
    try operations.applying(
      .divide,
      left: percentage.points,
      right: .integer(IntegerValue(100))
    )
  }

  private func requireNumber(
    _ value: EngineValue,
    at range: SourceRange? = nil
  ) throws -> NumericValue {
    guard case .number(let number) = value else {
      throw typeMismatch(
        expected: .number,
        actual: value.kind,
        range: range
      )
    }
    return number
  }

  private func requirePercentage(
    _ value: EngineValue,
    at range: SourceRange? = nil
  ) throws -> PercentageValue {
    guard case .percentage(let percentage) = value else {
      throw typeMismatch(
        expected: .percentage,
        actual: value.kind,
        range: range
      )
    }
    return percentage
  }

  private func typeMismatch(
    expected: EngineValueKind,
    actual: EngineValueKind,
    range: SourceRange? = nil
  ) -> EngineError {
    EngineError(
      code: .typeMismatch,
      ranges: range.map { [$0] } ?? [],
      context: .typeMismatch(expected: expected, actual: actual)
    )
  }

  private mutating func evaluate(
    _ literal: NumericLiteral,
    range: SourceRange
  ) throws -> NumericValue {
    switch literal {
    case .integer(let digits, let radix):
      let integer = try IntegerValue(digits, radix: radix)
      try validate(integer, at: range)
      return .integer(integer)

    case .decimal(let digits, let fractionalDigitCount, let exponent):
      let (scale, overflow) = fractionalDigitCount.subtractingReportingOverflow(
        exponent
      )
      guard
        !overflow,
        scale != .min,
        Swift.abs(scale) <= limits.maximumDecimalScaleMagnitude
      else {
        throw limitError(.decimalScale, range: range)
      }
      let coefficient = try IntegerValue(digits)
      try validate(coefficient, at: range)
      return .decimal(
        try DecimalValue(coefficient: coefficient, scale: scale)
      )
    }
  }

  @inline(never)
  private func evaluateAssistantPrompt(_ prompt: String, nameRange: SourceRange) throws
    -> EngineValue
  {
    guard !prompt.isEmpty else {
      throw EngineError(code: .invalidDomain, ranges: [nameRange])
    }
    switch context.assistantAnswers[prompt] {
    case .value(let value):
      return value
    case .unusable:
      throw EngineError(
        code: .unusableAssistantAnswer,
        ranges: [nameRange],
        context: .assistantPrompt(prompt)
      )
    case nil:
      throw EngineError(
        code: .unresolvedAssistantPrompt,
        ranges: [nameRange],
        context: .assistantPrompt(prompt)
      )
    }
  }

  @inline(never)
  private mutating func evaluateCall(
    name: String,
    nameRange: SourceRange,
    arguments: [Expression]
  ) throws -> EngineValue {
    guard arguments.count <= limits.maximumFunctionArguments else {
      throw limitError(.functionArguments, range: nameRange)
    }
    if let finance = FinanceFunction(rawValue: name) {
      let expected = FinanceFunction.argumentCount...FinanceFunction.argumentCount
      try requireArguments(expected, of: name, given: arguments.count, at: nameRange)
      return try evaluateFinance(finance, arguments, nameRange: nameRange)
    }
    if let statistics = StatisticsFunction(rawValue: name) {
      try requireArguments(
        1...limits.maximumFunctionArguments, of: name, given: arguments.count, at: nameRange)
      return try evaluate(
        statistics.aggregate,
        of: try arguments.map { try evaluate($0) }
      )
    }
    guard let function = BuiltInFunction(rawValue: name) else {
      throw EngineError(code: .unknownFunction, ranges: [nameRange])
    }
    try requireArguments(
      function.argumentRange, of: name, given: arguments.count, at: nameRange)
    return .number(try evaluateNumeric(function, arguments, nameRange: nameRange))
  }

  private func requireArguments(
    _ expected: ClosedRange<Int>,
    of name: String,
    given: Int,
    at nameRange: SourceRange
  ) throws {
    guard !expected.contains(given) else {
      return
    }
    throw EngineError(
      code: .argumentCountMismatch,
      ranges: [nameRange],
      context: .argumentCount(function: name, expected: expected, actual: given)
    )
  }

  @inline(never)
  private mutating func evaluateNumeric(
    _ function: BuiltInFunction,
    _ arguments: [Expression],
    nameRange: SourceRange
  ) throws -> NumericValue {

    let evaluated = try arguments.map { try evaluate($0) }
    // An angle carries its unit, so `sin(30°)` does not depend on the angle mode.
    if [.sine, .cosine, .tangent].contains(function), evaluated.count == 1,
      case .quantity(let angle) = evaluated[0], angle.unit.dimension == .angle,
      case .ratio(let unit) = angle.unit
    {
      return try located(at: arguments[0].range) {
        let radians = try operations.applying(
          .multiply, left: angle.magnitude, right: unit.scaleToCanonical)
        return try NumericOperations(context: context.with(angleMode: .radians), limits: limits)
          .transcendental(function, value: radians)
      }
    }
    let values = try zip(evaluated, arguments).map { value, argument in
      try requireNumber(value, at: argument.range)
    }
    if function == .squareRoot {
      return try evaluateRoot(
        value: values[0],
        valueRange: arguments[0].range,
        degree: .integer(IntegerValue(2)),
        degreeRange: nameRange
      )
    }
    if function == .cubeRoot {
      return try evaluateRoot(
        value: values[0],
        valueRange: arguments[0].range,
        degree: .integer(IntegerValue(3)),
        degreeRange: nameRange
      )
    }
    if function == .root {
      return try evaluateRoot(
        value: values[0],
        valueRange: arguments[0].range,
        degree: values[1],
        degreeRange: arguments[1].range
      )
    }

    let errorRange =
      arguments.count == 1
      ? arguments[0].range
      : nameRange
    return try located(at: errorRange) {
      switch function {
      case .absoluteValue:
        return try operations.absoluteValue(values[0])
      case .minimum:
        return try operations.extremum(values, selectMinimum: true)
      case .maximum:
        return try operations.extremum(values, selectMinimum: false)
      case .round:
        let places: Int
        if values.count == 2 {
          guard let count = operations.exactInteger(values[1]), count >= 0 else {
            throw EngineError(code: .invalidDomain)
          }
          places = count
        } else {
          places = 0
        }
        return try operations.rounded(
          values[0],
          fractionDigits: places,
          rule: context.precision.roundingRule.floatingPointRule
        )
      case .floor:
        return try operations.rounded(values[0], rule: .down)
      case .ceiling:
        return try operations.rounded(values[0], rule: .up)
      case .truncate:
        return try operations.rounded(values[0], rule: .towardZero)
      case .sign:
        return try operations.sign(values[0])
      case .factorial:
        return try operations.factorial(values[0])
      case .hypot:
        return try operations.hypot(values[0], values[1])
      case .remainder:
        return try operations.remainder(values[0], values[1])
      case .clamp:
        return try operations.clamp(values[0], lower: values[1], upper: values[2])
      case .arcTangent2:
        return try operations.arcTangent2(y: values[0], x: values[1])
      case .squareRoot, .cubeRoot:
        return try operations.root(
          values[0],
          degree: .integer(IntegerValue(function == .squareRoot ? 2 : 3))
        )
      case .root:
        return try operations.root(values[0], degree: values[1])
      case .sine, .cosine, .tangent,
        .arcSine, .arcCosine, .arcTangent,
        .naturalLogarithm, .commonLogarithm, .commonLogarithmExplicit,
        .binaryLogarithm, .exponential:
        return try operations.transcendental(function, value: values[0])
      }
    }
  }

  /// Compounding one rate over whole periods, which is exact arithmetic on
  /// the amount's own kind, so money stays money in its currency.
  @inline(never)
  private mutating func evaluateFinance(
    _ function: FinanceFunction,
    _ arguments: [Expression],
    nameRange: SourceRange
  ) throws -> EngineValue {
    let amount = try evaluate(arguments[0])
    switch amount {
    case .number, .money:
      break
    default:
      throw typeMismatch(expected: .money, actual: amount.kind, range: arguments[0].range)
    }
    let rate = try requireRate(try evaluate(arguments[1]), at: arguments[1].range)
    let periods = try requirePeriods(try evaluate(arguments[2]), at: arguments[2].range)
    trace.financeUses.insert(function)

    let one = NumericValue.integer(IntegerValue(1))
    return try located(at: nameRange) {
      let growth = try operations.applying(
        .power,
        left: try operations.applying(.add, left: one, right: rate),
        right: .integer(IntegerValue(periods))
      )
      switch function {
      case .futureValue:
        return try apply(.multiply, left: amount, right: .number(growth))
      case .presentValue:
        return try apply(.divide, left: amount, right: .number(growth))
      case .payment:
        guard !rate.isZero else {
          return try apply(
            .divide, left: amount, right: .number(.integer(IntegerValue(periods))))
        }
        let discounted = try operations.applying(
          .subtract, left: one, right: try operations.applying(.divide, left: one, right: growth))
        return try apply(
          .multiply,
          left: amount,
          right: .number(try operations.applying(.divide, left: rate, right: discounted))
        )
      }
    }
  }

  /// A rate for one period, written as a percentage or a plain fraction.
  private func requireRate(_ value: EngineValue, at range: SourceRange) throws -> NumericValue {
    if case .percentage(let percentage) = value {
      return try percentageRate(percentage)
    }
    return try requireNumber(value, at: range)
  }

  /// A whole number of periods, at least one. A fraction of a period would
  /// mean a compounding rule the caller did not state.
  private func requirePeriods(_ value: EngineValue, at range: SourceRange) throws -> Int {
    guard case .number(.integer(let periods)) = value, let count = Int(exactly: periods.storage),
      count > 0, count <= limits.maximumPowerExponent
    else {
      throw EngineError(code: .invalidDomain, ranges: [range])
    }
    return count
  }

  private func evaluateRoot(
    value: NumericValue,
    valueRange: SourceRange,
    degree: NumericValue,
    degreeRange: SourceRange
  ) throws -> NumericValue {
    do {
      return try operations.root(value, degree: degree)
    } catch let error as EngineError {
      let range: SourceRange
      switch error.context {
      case .rootDegree, .resourceLimit(.rootDegree):
        range = degreeRange
      default:
        range = valueRange
      }
      throw error.ranges.isEmpty ? error.located(at: range) : error
    }
  }

  private mutating func visit(_ range: SourceRange) throws {
    visitedOperations += 1
    guard visitedOperations <= limits.maximumOperations else {
      throw limitError(.operations, range: range)
    }
  }

  private func validate(_ integer: IntegerValue, at range: SourceRange) throws {
    guard integer.storage.magnitude.bitWidth <= limits.maximumIntegerBits else {
      throw limitError(.integerBits, range: range)
    }
  }

  private func located<T>(
    at range: SourceRange,
    operation: () throws -> T
  ) throws -> T {
    do {
      return try operation()
    } catch let error as EngineError {
      throw error.ranges.isEmpty ? error.located(at: range) : error
    }
  }

  private func limitError(
    _ resource: EvaluationResource,
    range: SourceRange
  ) -> EngineError {
    EngineError(
      code: .resourceLimitExceeded,
      ranges: [range],
      context: .resourceLimit(resource)
    )
  }
}

extension EngineError {
  fileprivate func located(at range: SourceRange) -> EngineError {
    EngineError(
      code: code,
      severity: severity,
      ranges: [range],
      fixIts: fixIts,
      context: context
    )
  }
}
