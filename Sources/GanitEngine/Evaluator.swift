import Foundation

public struct Evaluator: Sendable {
  private let context: EvaluationContext
  private let limits: EvaluationLimits

  public init(
    context: EvaluationContext,
    limits: EvaluationLimits = .default
  ) {
    self.context = context
    self.limits = limits
  }

  public func evaluate(_ expression: Expression) throws -> EngineValue {
    var worker = EvaluationWorker(context: context, limits: limits)
    return try worker.evaluate(expression)
  }
}

private struct EvaluationWorker {
  let context: EvaluationContext
  let limits: EvaluationLimits
  let operations: NumericOperations
  var visitedOperations = 0

  init(context: EvaluationContext, limits: EvaluationLimits) {
    self.context = context
    self.limits = limits
    operations = NumericOperations(context: context, limits: limits)
  }

  mutating func evaluate(_ expression: Expression) throws -> EngineValue {
    try visit(expression.range)

    do {
      switch expression {
      case .literal(let literal, let range):
        return .number(try evaluate(literal, range: range))

      case .identifier(let name, let range):
        switch name {
        case "π", "pi":
          return .number(
            .approximate(
              try ApproximateValue(
                estimate: .pi,
                source: .mathematicalConstant,
                precision: .requestedSignificantDecimalDigits(
                  context.precision.transcendentalSignificantDigits
                )
              )
            ))
        case "e":
          return .number(
            .approximate(
              try ApproximateValue(
                estimate: Foundation.exp(1),
                source: .mathematicalConstant,
                precision: .requestedSignificantDecimalDigits(
                  context.precision.transcendentalSignificantDigits
                )
              )
            ))
        default:
          throw EngineError(code: .unknownIdentifier, ranges: [range])
        }

      case .prefix(
        let unaryOperator,
        let operand,
        let operatorRange,
        _
      ):
        let value = try evaluate(operand)
        return try located(at: operatorRange) {
          try apply(unaryOperator, to: value)
        }

      case .infix(
        let left,
        let binaryOperator,
        let right,
        let operatorRange,
        _
      ):
        let lhs = try evaluate(left)
        let rhs = try evaluate(right)
        let errorRange =
          binaryOperator == .divide || binaryOperator == .power
          ? right.range
          : operatorRange
        return try located(at: errorRange) {
          try apply(binaryOperator, left: lhs, right: rhs)
        }

      case .call(let name, let nameRange, let arguments, _):
        return .number(
          try evaluateCall(
            name: name,
            nameRange: nameRange,
            arguments: arguments
          ))

      case .percentage(let points, _, _):
        let value = try evaluate(points)
        return .percentage(
          PercentageValue(points: try requireNumber(value, at: points.range))
        )

      case .percentageOperation(
        let percentageOperator,
        let left,
        let right,
        let operatorRange,
        _
      ):
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

      case .grouped(let nested, _):
        return try evaluate(nested)
      }
    } catch let error as EngineError where error.ranges.isEmpty {
      throw error.located(at: expression.range)
    }
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
    }
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
