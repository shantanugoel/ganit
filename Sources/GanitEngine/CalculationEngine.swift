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
    evaluate(
      source,
      context: context,
      origin: .start,
      variables: [:],
      lines: LineOutcomes()
    ).result
  }

  func evaluate(
    _ source: String,
    context: EvaluationContext,
    origin: SourceLocation,
    variables: [String: EngineValue?],
    lines: LineOutcomes
  ) -> (result: CalculationResult, expression: Expression?) {
    let parsing = Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits,
      catalog: unitCatalog,
      origin: origin,
      variables: variables.mapValues { $0?.kind ?? .number }
    ).parse()
    guard let expression = parsing.expression else {
      return (.syntaxFailure(parsing.diagnostics), nil)
    }

    do {
      let value = try Evaluator(
        context: context,
        limits: evaluationLimits,
        variables: variables,
        lines: lines
      ).evaluate(expression)
      return (.value(value), expression)
    } catch let error as EngineError {
      return (.evaluationFailure(error), expression)
    } catch {
      return (
        .evaluationFailure(
          EngineError(code: .internalFailure, ranges: [expression.range])
        ),
        expression
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

  public func parse(
    _ source: String,
    context: EvaluationContext
  ) -> ParsingResult {
    Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits,
      catalog: unitCatalog
    ).parse()
  }
}
