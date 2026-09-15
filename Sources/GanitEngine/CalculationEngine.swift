public enum CalculationResult: Hashable, Sendable {
  case value(EngineValue)
  case syntaxFailure([SyntaxDiagnostic])
  case evaluationFailure(EngineError)
}

public struct CalculationEngine: Sendable {
  private let syntaxLimits: SyntaxLimits
  private let evaluationLimits: EvaluationLimits
  private let unitCatalog: UnitCatalog

  public init(
    syntaxLimits: SyntaxLimits = .default,
    evaluationLimits: EvaluationLimits = .default,
    unitCatalog: UnitCatalog? = nil
  ) {
    self.syntaxLimits = syntaxLimits
    self.evaluationLimits = evaluationLimits
    self.unitCatalog = unitCatalog ?? builtInMinimalUnitCatalog
  }

  public func evaluate(
    _ source: String,
    context: EvaluationContext
  ) -> CalculationResult {
    let parsing = parse(source, context: context)
    guard let expression = parsing.expression else {
      return .syntaxFailure(parsing.diagnostics)
    }
    return evaluate(expression, context: context, variables: [:], lines: LineOutcomes()).result
  }

  /// Parses an expression located at `origin`, resolving the given visible
  /// variable names and kinds.
  public func parse(
    _ source: String,
    context: EvaluationContext,
    origin: SourceLocation = .start,
    variables: [String: EngineValueKind] = [:]
  ) -> ParsingResult {
    Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits,
      catalog: unitCatalog,
      origin: origin,
      variables: variables
    ).parse()
  }

  func evaluate(
    _ expression: Expression,
    context: EvaluationContext,
    variables: [String: EngineValue?],
    lines: LineOutcomes
  ) -> (result: CalculationResult, clock: ClockResolution?) {
    let (result, clock) = Evaluator(
      context: context,
      limits: evaluationLimits,
      variables: variables,
      lines: lines
    ).evaluateReadingClock(expression)
    switch result {
    case .success(let value):
      return (.value(value), clock)
    case .failure(let error as EngineError):
      return (.evaluationFailure(error), clock)
    case .failure:
      return (
        .evaluationFailure(EngineError(code: .internalFailure, ranges: [expression.range])), clock
      )
    }
  }

  /// Returns a declaration's normalized name, or `nil` when it is not a
  /// sequence of words that are not keywords, constants, functions, or units.
  /// A single-word name also cannot be a reference keyword.
  func variableName(
    in source: String,
    context: EvaluationContext
  ) -> String? {
    let lexing = Lexer(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits
    ).lex()
    var words: [String] = []
    for token in lexing.tokens.dropLast() {
      guard case .identifier(let word) = token.kind,
        !reservedIdentifiers.contains(word),
        BuiltInFunction(rawValue: word) == nil,
        unitCatalog.resolveUnit(matching: word) == nil
      else {
        return nil
      }
      words.append(word)
    }
    guard lexing.diagnostics.isEmpty, !words.isEmpty,
      words.count > 1 || (referenceKeywords[words[0]] == nil && words[0] != "line")
    else {
      return nil
    }
    return words.joined(separator: " ")
  }
}
