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
      dollarCurrency: context.dollarCurrency,
      ambiguousSuffixes: context.ambiguousSuffixes
    ).parse()
  }

  func evaluate(
    _ expression: Expression,
    context: EvaluationContext,
    variables: [String: EngineValue?],
    lines: LineOutcomes,
    manualRates: [CurrencyPair: NumericValue] = [:],
    functions: [String: CustomFunction] = [:]
  ) -> (result: CalculationResult, trace: EvaluationTrace) {
    let (result, trace) = Evaluator(
      context: context,
      limits: evaluationLimits,
      variables: variables,
      lines: lines,
      manualRates: manualRates,
      functions: functions
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
  /// A reference keyword such as `total` may be a name; below it, the name
  /// means the variable.
  func variableName(
    in source: String,
    context: EvaluationContext
  ) -> String? {
    name(in: source, context: context, redefinable: []).name
  }

  /// A function definition's name and parameters, from `area(w, h)`: a word
  /// that could name a variable, `(` right after it, and single words that
  /// are not keywords or functions. A parameter may be a unit's word, such as
  /// `h`, since inside the body it means the parameter. `Groceries (Costco)`,
  /// with a space, is not one.
  func functionSignature(
    in source: String,
    context: EvaluationContext
  ) -> (name: String, parameters: [String])? {
    let lexing = Lexer(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits
    ).lex()
    let tokens = Array(lexing.tokens.dropLast())
    guard lexing.diagnostics.isEmpty, tokens.count >= 3,
      case .identifier(let name) = tokens[0].kind,
      tokens[1].kind == .leftParenthesis,
      tokens[1].range.lowerBound == tokens[0].range.upperBound,
      tokens[tokens.count - 1].kind == .rightParenthesis,
      variableName(in: name, context: context) != nil
    else {
      return nil
    }
    var parameters: [String] = []
    for (index, token) in tokens.dropFirst(2).dropLast().enumerated() {
      if index.isMultiple(of: 2) {
        guard case .identifier(let word) = token.kind,
          !reservedIdentifiers.contains(word), BuiltInFunction(rawValue: word) == nil,
          FinanceFunction(rawValue: word) == nil,
          !parameters.contains(word.lowercased())
        else {
          return nil
        }
        parameters.append(word.lowercased())
      } else if token.kind != .argumentSeparator {
        return nil
      }
    }
    // `f(x,)` leaves a separator with no word after it.
    guard tokens.count == 3 || tokens[tokens.count - 2].kind != .argumentSeparator else {
      return nil
    }
    return (name.lowercased(), parameters)
  }

  /// Why a declaration's name cannot be one, with the range it is at.
  enum NameProblem {
    /// A word that already means a unit, function, or keyword.
    case takenWord(SourceRange)
    /// Something that is not a word at all, such as `(` or a digit.
    case notWords(SourceRange)
  }

  /// What keeps `source` from being a variable name, relative to `source`.
  func nameProblem(
    in source: String,
    context: EvaluationContext
  ) -> NameProblem? {
    name(in: source, context: context, redefinable: []).problem
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
    return name(in: source, context: context, redefinable: custom).name
  }

  private func name(
    in source: String,
    context: EvaluationContext,
    redefinable: Set<String>
  ) -> (name: String?, problem: NameProblem?) {
    let lexing = Lexer(
      source: source,
      configuration: context.lexingConfiguration,
      limits: syntaxLimits
    ).lex()
    guard lexing.diagnostics.isEmpty else {
      return (nil, nil)
    }
    var words: [String] = []
    for token in lexing.tokens.dropLast() {
      guard case .identifier(let word) = token.kind else {
        return (nil, .notWords(token.range))
      }
      guard !reservedIdentifiers.contains(word),
        BuiltInFunction(rawValue: word) == nil,
        FinanceFunction(rawValue: word) == nil,
        unitCatalog.resolveUnit(matching: word) == nil || redefinable.contains(word),
        CurrencyCatalog.minorUnits[word.uppercased()] == nil
      else {
        return (nil, .takenWord(token.range))
      }
      words.append(word)
    }
    // `line 3` is a reference, so `line` alone cannot be a name.
    if words == ["line"], let first = lexing.tokens.first {
      return (nil, .takenWord(first.range))
    }
    return words.isEmpty ? (nil, nil) : (words.joined(separator: " "), nil)
  }
}
