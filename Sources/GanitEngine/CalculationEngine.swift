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

  /// This engine, resolving these custom units in addition to its catalog's
  /// units and no others. A unit the catalog refuses is dropped.
  public func resolving(_ units: [CustomUnit]) -> CalculationEngine {
    guard let catalog = try? unitCatalog.replacingCustomUnits(with: units) else {
      return self
    }
    return CalculationEngine(
      syntaxLimits: syntaxLimits,
      evaluationLimits: evaluationLimits,
      unitCatalog: catalog
    )
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
      variables: variables,
      dollarCurrency: context.dollarCurrency
    ).parse()
  }

  func evaluate(
    _ expression: Expression,
    context: EvaluationContext,
    variables: [String: EngineValue?],
    lines: LineOutcomes,
    manualRates: [CurrencyPair: NumericValue] = [:]
  ) -> (result: CalculationResult, trace: EvaluationTrace) {
    let (result, trace) = Evaluator(
      context: context,
      limits: evaluationLimits,
      variables: variables,
      lines: lines,
      manualRates: manualRates
    ).evaluateTracing(expression)
    switch result {
    case .success(let value):
      return (.value(value), trace)
    case .failure(let error as EngineError):
      return (.evaluationFailure(error), trace)
    case .failure:
      return (
        .evaluationFailure(EngineError(code: .internalFailure, ranges: [expression.range])), trace
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
    name(in: source, context: context, redefinable: [])
  }

  /// Returns a unit definition's name, or `nil` when it is not one word that
  /// may name a unit. A custom unit's own name may be redefined; a unit a
  /// data source names may not.
  func unitName(
    in source: String,
    context: EvaluationContext
  ) -> String? {
    let custom = Set(
      unitCatalog.entries.filter { $0.sourceIdentifier == nil }.flatMap(\.aliases)
    )
    return name(in: source, context: context, redefinable: custom)
  }

  private func name(
    in source: String,
    context: EvaluationContext,
    redefinable: Set<String>
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
        FinanceFunction(rawValue: word) == nil,
        unitCatalog.resolveUnit(matching: word) == nil || redefinable.contains(word),
        CurrencyCatalog.minorUnits[word] == nil
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
