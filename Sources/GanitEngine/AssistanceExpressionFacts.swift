import Foundation

/// Facts from the native expression tree. This is not another parser.
struct AssistanceExpressionFacts {
  struct Literal {
    let source: String
    let value: EngineValue
    let range: SourceRange
    let structuralRule: String?
  }
  var literals: [Literal] = []
  var identifiers: Set<String> = []
  var calls: Set<String> = []
  var references: Set<LineReference> = []
  var containsAssistant = false
  var readsClock = false
  var unitConstants: [Int] = []
  var unitIdentifiers: Set<String> = []
  var temporal: [(text: String, literal: TemporalLiteral, range: SourceRange)] = []

  init(
    _ expression: Expression, source: String, engine: CalculationEngine, context: EvaluationContext
  ) {
    var work: [(Expression, String?)] = [(expression, nil)]
    while let (node, structuralRule) = work.popLast() {
      switch node {
      case .literal(_, let range):
        let text = range.text(in: source).map(String.init) ?? ""
        if case .value(let value) = engine.evaluate(
          node, context: context, variables: [:], lines: LineOutcomes()
        ).result {
          literals.append(
            Literal(source: text, value: value, range: range, structuralRule: structuralRule))
        }
      case .percentage(let points, _, let range):
        if case .literal = points {
          let text = range.text(in: source).map(String.init) ?? ""
          if case .value(let value) = engine.evaluate(text, context: context) {
            literals.append(Literal(source: text, value: value, range: range, structuralRule: nil))
          }
        } else {
          work.append((points, nil))
        }
      case .identifier(let name, _): identifiers.insert(name.lowercased())
      case .assistantPrompt: containsAssistant = true
      case .reference(let reference, _): references.insert(reference)
      case .call(let name, _, let arguments, _):
        calls.insert(name.lowercased())
        work.append(contentsOf: arguments.map { ($0, nil) })
      case .temporal(let literal, let range):
        temporal.append((range.text(in: source).map(String.init) ?? "", literal, range))
        switch literal {
        case .now, .relativeDay, .weekday: readsClock = true
        case .date(let year, _, _): if year == nil { readsClock = true }
        default: break
        }
      case .relative(let offset, _, _):
        readsClock = true
        work.append((offset, nil))
      case .infix(let left, let op, let right, _, _):
        let leftRule = op == .multiply ? "identity" : nil
        let rightRule = op == .multiply || op == .divide ? "identity" : nil
        work.append((left, leftRule))
        work.append((right, op == .divide ? "division_denominator" : rightRule))
        if op == .divide, case .grouped(let denominator, _) = right,
          case .infix(let one, .subtract, let percent, _, _) = denominator,
          case .percentage = percent
        {
          work.removeLast()
          work.append((one, "profit_margin_identity"))
          work.append((percent, nil))
        }
      case .percentageOperation(_, let left, let right, _, _):
        work.append((left, nil))
        work.append((right, nil))
      case .money(let operand, _, let range):
        if isPrimitive(operand),
          case .value(let value) = engine.evaluate(
            node, context: context, variables: [:], lines: LineOutcomes()
          ).result
        {
          literals.append(
            Literal(
              source: range.text(in: source).map(String.init) ?? "", value: value, range: range,
              structuralRule: nil))
        } else {
          work.append((operand, nil))
        }
      case .prefix(_, let operand, _, _), .currencyConversion(let operand, _, _),
        .zoneConversion(let operand, _, _),
        .period(let operand, _, _):
        work.append((operand, nil))
      case .grouped(let operand, _): work.append((operand, structuralRule))
      case .quantity(let operand, let unit, let range):
        if isPrimitive(operand),
          case .value(let value) = engine.evaluate(
            node, context: context, variables: [:], lines: LineOutcomes()
          ).result
        {
          literals.append(
            Literal(
              source: range.text(in: source).map(String.init) ?? "", value: value, range: range,
              structuralRule: nil))
        } else {
          work.append((operand, nil))
        }
        inspect(unit)
      case .conversion(let operand, let unit, _, _):
        work.append((operand, nil))
        inspect(unit)
      }
    }
  }

  static func isPrimitive(_ expression: Expression) -> Bool {
    switch expression {
    case .literal: return true
    case .grouped(let value, _), .prefix(_, let value, _, _): return isPrimitive(value)
    default: return false
    }
  }

  private func isPrimitive(_ expression: Expression) -> Bool { Self.isPrimitive(expression) }

  private mutating func inspect(_ syntax: UnitSyntax) {
    var work = [syntax]
    while let unit = work.popLast() {
      switch unit {
      case .named(let entry, _, _): unitIdentifiers.insert(entry.definition.canonicalIdentifier)
      case .multiplied(let left, let right, _), .divided(let left, let right, _):
        work.append(left)
        work.append(right)
      case .raised(let operand, let exponent, _):
        unitConstants.append(exponent)
        work.append(operand)
      case .counted(let count, let operand, _):
        unitConstants.append(count)
        work.append(operand)
      }
    }
  }
}

func assistanceValuesEqual(_ left: EngineValue, _ right: EngineValue, context: EvaluationContext)
  -> Bool
{
  func numeric(_ left: NumericValue, _ right: NumericValue) -> Bool {
    (try? NumericOperations(context: context, limits: .default).applying(
      .subtract, left: left, right: right
    ).isZero) == true
  }
  switch (left, right) {
  case (.number(let a), .number(let b)): return numeric(a, b)
  case (.percentage(let a), .percentage(let b)): return numeric(a.points, b.points)
  case (.money(let a), .money(let b)):
    return a.currency == b.currency && a.unit == b.unit && numeric(a.amount, b.amount)
  case (.quantity(let a), .quantity(let b)):
    guard a.kind == b.kind,
      let converted = try? UnitAlgebra(context: context).converted(a, to: b.unit)
    else { return false }
    return numeric(converted.magnitude, b.magnitude)
  default: return left == right
  }
}

func assistanceLiteralValuesEqual(
  _ left: EngineValue, _ right: EngineValue, context: EvaluationContext
) -> Bool {
  if case .quantity(let a) = left, case .quantity(let b) = right {
    guard a.unit == b.unit, a.kind == b.kind else { return false }
    return assistanceValuesEqual(.number(a.magnitude), .number(b.magnitude), context: context)
  }
  return assistanceValuesEqual(left, right, context: context)
}
