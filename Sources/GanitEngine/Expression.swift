public enum UnaryOperator: Hashable, Sendable {
  case plus
  case minus
  /// `√2`, the same as `sqrt(2)`.
  case squareRoot
}

public enum BinaryOperator: Hashable, Sendable {
  case add
  case subtract
  case multiply
  case divide
  case power
  case bitwiseAnd
  case bitwiseOr
  case shiftLeft
  case shiftRight
}

public enum PercentageOperator: Hashable, Sendable {
  case of
  case off
  case on
  case ratio
  case change
  case reverseOff
  case reverseOn
}

public indirect enum UnitSyntax: Hashable, Sendable {
  case named(
    UnitCatalogEntry,
    prefix: UnitPrefixEntry?,
    range: SourceRange
  )
  case multiplied(UnitSyntax, UnitSyntax, range: SourceRange)
  case divided(UnitSyntax, UnitSyntax, range: SourceRange)
  case raised(UnitSyntax, exponent: Int, range: SourceRange)
  /// A count of a unit as one unit, as in the `100 km` of `L/100 km`.
  case counted(Int, UnitSyntax, range: SourceRange)

  public var range: SourceRange {
    switch self {
    case .named(_, _, let range),
      .multiplied(_, _, let range),
      .divided(_, _, let range),
      .raised(_, _, let range),
      .counted(_, _, let range):
      return range
    }
  }
}

/// A reference to results on lines above the current line.
public enum LineReference: Hashable, Sendable {
  /// A one-based sheet line number.
  case line(Int)
  case previous
  case aggregate(Aggregate)
}

public enum Aggregate: String, Hashable, Sendable {
  case sum
  case subtotal
  case average
  case median
  case count
}

public indirect enum Expression: Hashable, Sendable {
  case literal(NumericLiteral, range: SourceRange)
  case temporal(TemporalLiteral, range: SourceRange)
  /// A period or duration before or after now: `3 days ago`, `2 h from now`.
  case relative(offset: Expression, isPast: Bool, range: SourceRange)
  /// An amount of a currency: `12.50 EUR`, `€12.50`.
  case money(amount: Expression, currency: String, range: SourceRange)
  /// Money converted to another currency: `100 USD in EUR`.
  case currencyConversion(value: Expression, currency: String, range: SourceRange)
  /// An instant shown in an IANA zone: `now in Asia/Tokyo`.
  case zoneConversion(value: Expression, zone: String, range: SourceRange)
  case identifier(String, range: SourceRange)
  case prefix(
    UnaryOperator,
    operand: Expression,
    operatorRange: SourceRange,
    range: SourceRange
  )
  case infix(
    left: Expression,
    operator: BinaryOperator,
    right: Expression,
    operatorRange: SourceRange,
    range: SourceRange
  )
  case call(
    name: String,
    nameRange: SourceRange,
    arguments: [Expression],
    range: SourceRange
  )
  case percentage(
    points: Expression,
    percentRange: SourceRange,
    range: SourceRange
  )
  case percentageOperation(
    operator: PercentageOperator,
    left: Expression,
    right: Expression,
    operatorRange: SourceRange,
    range: SourceRange
  )
  case quantity(
    magnitude: Expression,
    unit: UnitSyntax,
    range: SourceRange
  )
  /// A whole count of calendar days, weeks, months, quarters, or years.
  case period(
    count: Expression,
    unit: CalendarPeriodUnit,
    range: SourceRange
  )
  case conversion(
    value: Expression,
    target: UnitSyntax,
    keywordRange: SourceRange,
    range: SourceRange
  )
  case grouped(Expression, range: SourceRange)
  case reference(LineReference, range: SourceRange)
  /// The text inside the parentheses is the prompt, not an expression.
  case assistantPrompt(
    name: String,
    prompt: String,
    nameRange: SourceRange,
    range: SourceRange
  )

  public var range: SourceRange {
    switch self {
    case .literal(_, let range),
      .temporal(_, let range),
      .relative(_, _, let range),
      .zoneConversion(_, _, let range),
      .money(_, _, let range),
      .currencyConversion(_, _, let range),
      .identifier(_, let range),
      .prefix(_, _, _, let range),
      .infix(_, _, _, _, let range),
      .call(_, _, _, let range),
      .percentage(_, _, let range),
      .percentageOperation(_, _, _, _, let range),
      .quantity(_, _, let range),
      .period(_, _, let range),
      .conversion(_, _, _, let range),
      .grouped(_, let range),
      .reference(_, let range),
      .assistantPrompt(_, _, _, let range):
      return range
    }
  }

  /// Every line reference in the expression.
  var references: Set<LineReference> {
    switch self {
    case .reference(let reference, _):
      return [reference]
    case .literal, .temporal, .identifier, .assistantPrompt:
      return []
    case .prefix(_, let operand, _, _),
      .percentage(let operand, _, _),
      .quantity(let operand, _, _),
      .period(let operand, _, _),
      .relative(let operand, _, _),
      .zoneConversion(let operand, _, _),
      .money(let operand, _, _),
      .currencyConversion(let operand, _, _),
      .conversion(let operand, _, _, _),
      .grouped(let operand, _):
      return operand.references
    case .infix(let left, _, let right, _, _),
      .percentageOperation(_, let left, let right, _, _):
      return left.references.union(right.references)
    case .call(_, _, let arguments, _):
      return arguments.reduce(into: []) { $0.formUnion($1.references) }
    }
  }

  /// Prompts `ask_assistant` and `prompt_assistant` would send.
  package var assistantPrompts: [String] {
    switch self {
    case .assistantPrompt(_, let prompt, _, _):
      return prompt.isEmpty ? [] : [prompt]
    case .literal, .temporal, .identifier, .reference:
      return []
    case .prefix(_, let operand, _, _),
      .percentage(let operand, _, _),
      .quantity(let operand, _, _),
      .period(let operand, _, _),
      .relative(let operand, _, _),
      .zoneConversion(let operand, _, _),
      .money(let operand, _, _),
      .currencyConversion(let operand, _, _),
      .conversion(let operand, _, _, _),
      .grouped(let operand, _):
      return operand.assistantPrompts
    case .infix(let left, _, let right, _, _),
      .percentageOperation(_, let left, let right, _, _):
      return left.assistantPrompts + right.assistantPrompts
    case .call(_, _, let arguments, _):
      return arguments.flatMap(\.assistantPrompts)
    }
  }
}

public struct ParsingResult: Equatable, Sendable {
  public let expression: Expression?
  public let diagnostics: [SyntaxDiagnostic]

  package init(expression: Expression?, diagnostics: [SyntaxDiagnostic]) {
    self.expression = expression
    self.diagnostics = diagnostics
  }
}
