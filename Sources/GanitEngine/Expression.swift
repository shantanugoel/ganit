public enum UnaryOperator: Equatable, Sendable {
  case plus
  case minus
}

public enum BinaryOperator: Equatable, Sendable {
  case add
  case subtract
  case multiply
  case divide
  case power
}

public enum PercentageOperator: Equatable, Sendable {
  case of
  case off
  case on
  case ratio
  case change
  case reverseOff
  case reverseOn
}

public indirect enum UnitSyntax: Equatable, Sendable {
  case named(
    UnitCatalogEntry,
    prefix: UnitPrefixEntry?,
    range: SourceRange
  )
  case multiplied(UnitSyntax, UnitSyntax, range: SourceRange)
  case divided(UnitSyntax, UnitSyntax, range: SourceRange)
  case raised(UnitSyntax, exponent: Int, range: SourceRange)

  public var range: SourceRange {
    switch self {
    case .named(_, _, let range),
      .multiplied(_, _, let range),
      .divided(_, _, let range),
      .raised(_, _, let range):
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

public indirect enum Expression: Equatable, Sendable {
  case literal(NumericLiteral, range: SourceRange)
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
  case conversion(
    value: Expression,
    target: UnitSyntax,
    keywordRange: SourceRange,
    range: SourceRange
  )
  case grouped(Expression, range: SourceRange)
  case reference(LineReference, range: SourceRange)

  public var range: SourceRange {
    switch self {
    case .literal(_, let range),
      .identifier(_, let range),
      .prefix(_, _, _, let range),
      .infix(_, _, _, _, let range),
      .call(_, _, _, let range),
      .percentage(_, _, let range),
      .percentageOperation(_, _, _, _, let range),
      .quantity(_, _, let range),
      .conversion(_, _, _, let range),
      .grouped(_, let range),
      .reference(_, let range):
      return range
    }
  }

  /// Every line reference in the expression.
  var references: Set<LineReference> {
    switch self {
    case .reference(let reference, _):
      return [reference]
    case .literal, .identifier:
      return []
    case .prefix(_, let operand, _, _),
      .percentage(let operand, _, _),
      .quantity(let operand, _, _),
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
}

public struct ParsingResult: Equatable, Sendable {
  public let expression: Expression?
  public let diagnostics: [SyntaxDiagnostic]

  package init(expression: Expression?, diagnostics: [SyntaxDiagnostic]) {
    self.expression = expression
    self.diagnostics = diagnostics
  }
}
