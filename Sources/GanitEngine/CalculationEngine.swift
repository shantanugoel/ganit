public enum CalculationResult: Hashable, Sendable {
  case value(EngineValue)
  case syntaxFailure([SyntaxDiagnostic])
  case evaluationFailure(EngineError)
}

public struct SheetLineResult: Hashable, Sendable {
  public let id: LineID
  public let syntax: LineSyntax
  /// The expression's result, or `nil` when the line has no expression.
  public let result: CalculationResult?
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

  /// Evaluates each line's expression independently. Ranges in results are
  /// sheet coordinates.
  public func evaluate(
    _ sheet: SheetSource,
    context: EvaluationContext
  ) -> [SheetLineResult] {
    sheet.lines.map { line in
      let syntax = LineSyntax(line)
      guard case .calculation(_, let expression?, _) = syntax else {
        return SheetLineResult(id: line.id, syntax: syntax, result: nil)
      }
      let utf8 = line.text.utf8
      let lower = utf8.index(
        utf8.startIndex,
        offsetBy: expression.lowerBound - line.range.lowerBound
      )
      let upper = utf8.index(lower, offsetBy: expression.utf8Length)
      return SheetLineResult(
        id: line.id,
        syntax: syntax,
        result: evaluate(
          String(line.text[lower..<upper]),
          context: context,
          origin: SourceLocation(
            utf8Offset: expression.lowerBound,
            graphemeOffset: expression.graphemeLowerBound
          )
        )
      )
    }
  }

  public func evaluate(
    _ source: String,
    context: EvaluationContext,
    origin: SourceLocation = .start
  ) -> CalculationResult {
    let parsing = parse(source, context: context, origin: origin)
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
    context: EvaluationContext,
    origin: SourceLocation = .start
  ) -> ParsingResult {
    Parser(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits,
      catalog: unitCatalog,
      origin: origin
    ).parse()
  }
}
