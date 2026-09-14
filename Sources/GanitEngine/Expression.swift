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
  case grouped(Expression, range: SourceRange)

  public var range: SourceRange {
    switch self {
    case .literal(_, let range),
      .identifier(_, let range),
      .prefix(_, _, _, let range),
      .infix(_, _, _, _, let range),
      .call(_, _, _, let range),
      .grouped(_, let range):
      return range
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
