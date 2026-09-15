import Foundation

public struct Evaluator: Sendable {
  private let context: EvaluationContext
  private let limits: EvaluationLimits
  private let variables: [String: EngineValue?]
  private let lines: LineOutcomes

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
  /// declaration failed. `lines` holds the results of lines above.
  init(
    context: EvaluationContext,
    limits: EvaluationLimits,
    variables: [String: EngineValue?],
    lines: LineOutcomes
  ) {
    self.context = context
    self.limits = limits
    self.variables = variables
    self.lines = lines
  }

  public func evaluate(_ expression: Expression) throws -> EngineValue {
    var worker = EvaluationWorker(
      context: context,
      limits: limits,
      variables: variables,
      lines: lines
    )
    return try worker.evaluate(expression)
  }
}

private struct EvaluationWorker {
  let context: EvaluationContext
  let limits: EvaluationLimits
  let operations: NumericOperations
  let unitAlgebra: UnitAlgebra
  let variables: [String: EngineValue?]
  let lines: LineOutcomes
  var visitedOperations = 0

  init(
    context: EvaluationContext,
    limits: EvaluationLimits,
    variables: [String: EngineValue?],
    lines: LineOutcomes
  ) {
    self.context = context
    self.limits = limits
    self.variables = variables
    self.lines = lines
    operations = NumericOperations(context: context, limits: limits)
    unitAlgebra = UnitAlgebra(context: context, limits: limits)
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
        return .number(try evaluateCall(name: name, nameRange: nameRange, arguments: arguments))
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
        throw EngineError(code: .unavailableReference, ranges: [range])
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
    let rhs = try evaluate(right)
    let errorRange =
      binaryOperator == .divide || binaryOperator == .power
      ? right.range
      : operatorRange
    return try located(at: errorRange) {
      try apply(binaryOperator, left: lhs, right: rhs)
    }
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
  private mutating func evaluateConversion(
    _ valueExpression: Expression,
    to targetSyntax: UnitSyntax
  ) throws -> EngineValue {
    let value = try evaluate(valueExpression)
    guard case .quantity(let quantity) = value else {
      throw typeMismatch(
        expected: .quantity,
        actual: value.kind,
        range: valueExpression.range
      )
    }
    let target = try located(at: targetSyntax.range) {
      try evaluate(targetSyntax)
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
    case .rate:
      throw typeMismatch(expected: .number, actual: value.kind)
    }
  }

  private func apply(
    _ binaryOperator: BinaryOperator,
    left: EngineValue,
    right: EngineValue
  ) throws -> EngineValue {
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
    }
  }

  private func evaluate(
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
    guard case .integer(let integer) = value,
      let exponent = Int(integer.canonicalDigits),
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
  private mutating func evaluateCall(
    name: String,
    nameRange: SourceRange,
    arguments: [Expression]
  ) throws -> NumericValue {
    guard let function = BuiltInFunction(rawValue: name) else {
      throw EngineError(code: .unknownFunction, ranges: [nameRange])
    }
    guard arguments.count <= limits.maximumFunctionArguments else {
      throw limitError(.functionArguments, range: nameRange)
    }
    guard function.argumentRange.contains(arguments.count) else {
      throw EngineError(
        code: .argumentCountMismatch,
        ranges: [nameRange],
        context: .argumentCount(
          function: function,
          expected: function.argumentRange,
          actual: arguments.count
        )
      )
    }

    let values = try arguments.map { argument in
      try requireNumber(try evaluate(argument), at: argument.range)
    }
    if function == .squareRoot {
      return try evaluateRoot(
        value: values[0],
        valueRange: arguments[0].range,
        degree: .integer(IntegerValue(2)),
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
        return try operations.rounded(
          values[0],
          rule: context.precision.roundingRule.floatingPointRule
        )
      case .floor:
        return try operations.rounded(values[0], rule: .down)
      case .ceiling:
        return try operations.rounded(values[0], rule: .up)
      case .squareRoot:
        return try operations.root(
          values[0],
          degree: .integer(IntegerValue(2))
        )
      case .root:
        return try operations.root(values[0], degree: values[1])
      case .sine, .cosine, .tangent,
        .arcSine, .arcCosine, .arcTangent,
        .naturalLogarithm, .commonLogarithm, .commonLogarithmExplicit,
        .exponential:
        return try operations.transcendental(function, value: values[0])
      }
    }
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
