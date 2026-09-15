public enum CalculationResult: Hashable, Sendable {
  case value(EngineValue)
  case syntaxFailure([SyntaxDiagnostic])
  case evaluationFailure(EngineError)
}

public struct CalculationEngine: Sendable {
  private let syntaxLimits: SyntaxLimits
  private let evaluationLimits: EvaluationLimits

  public init(
    syntaxLimits: SyntaxLimits = .default,
    evaluationLimits: EvaluationLimits = .default
  ) {
    self.syntaxLimits = syntaxLimits
    self.evaluationLimits = evaluationLimits
  }

  public func evaluate(
    _ source: String,
    context: EvaluationContext
  ) -> CalculationResult {
    let parsing = parse(source, context: context)
    guard let expression = parsing.expression else {
      return .syntaxFailure(parsing.diagnostics)
    }

    do {
      return .value(
        try Evaluator(
          context: context,
          limits: evaluationLimits
        ).evaluate(expression)
      )
    } catch let error as EngineError {
      return .evaluationFailure(error)
    } catch {
      return .evaluationFailure(
        EngineError(code: .internalFailure, ranges: [expression.range])
      )
    }
  }

  public func parse(
    _ source: String,
    context: EvaluationContext
  ) -> ParsingResult {
    Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits
    ).parse()
  }
}
