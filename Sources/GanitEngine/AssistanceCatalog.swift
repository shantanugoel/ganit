import Foundation

public struct AssistanceCatalog: Encodable, Sendable {
  public static let version = 1
  let version = Self.version
  let semanticRegistryVersion = AssistanceSemanticPolicy.version
  let functions: [Function]
  let operators: [String]
  let percentageOperations: [String]
  let reservedWords: [String]
  let referenceWords: [String]
  let unitPowers: [String: Int]
  let scaleWords = ScaleWord.digits
  let units: [Unit]
  let syntaxCodes: [String]
  let evaluationCodes: [String]
  let englishNumbers = AssistanceSnapshot.englishNumbers
  let structuralConstants = ["identity", "profit_margin_identity", "nominal_months"]
  let examples: [Example]
  let modelValueOperations = false

  struct Function: Encodable, Sendable {
    let name: String
    let minimumArguments: Int
    let maximumArguments: Int
  }
  struct Unit: Encodable, Sendable {
    let identifier: String
    let symbol: String
    let aliases: [String]
    let dimension: String
  }
  struct Example: Encodable, Sendable {
    let source: String
    let result: AssistanceValue
  }

  init(
    catalog: UnitCatalog, limits: EvaluationLimits, text: String, engine: CalculationEngine,
    context: EvaluationContext
  ) {
    functions =
      BuiltInFunction.allCases.map {
        Function(
          name: $0.rawValue, minimumArguments: $0.argumentRange.lowerBound,
          maximumArguments: min($0.argumentRange.upperBound, limits.maximumFunctionArguments))
      }
      + FinanceFunction.allCases.map {
        Function(
          name: $0.rawValue, minimumArguments: FinanceFunction.argumentCount,
          maximumArguments: FinanceFunction.argumentCount)
      }
      + StatisticsFunction.allCases.map {
        Function(
          name: $0.rawValue, minimumArguments: 1, maximumArguments: limits.maximumFunctionArguments)
      }
    operators =
      UnaryOperator.allCases.map { String(describing: $0) }
      + BinaryOperator.allCases.map { String(describing: $0) }
    percentageOperations = PercentageOperator.allCases.map { String(describing: $0) }
    reservedWords = reservedIdentifiers.sorted()
    referenceWords = referenceKeywords.keys.sorted()
    unitPowers = unitPowerWords
    syntaxCodes = SyntaxDiagnostic.Code.allCases.map(\.rawValue)
    evaluationCodes = EngineErrorCode.allCases.map(\.rawValue)
    let words = Lexer(source: text, configuration: context.lexingConfiguration).lex().tokens
      .compactMap { token -> String? in
        if case .identifier(let word) = token.kind { return word }
        return nil
      }
    let selected = Set(
      words.compactMap { catalog.resolveUnit(matching: $0)?.entry.definition.canonicalIdentifier })
    units = catalog.entries.filter { selected.contains($0.definition.canonicalIdentifier) }.map {
      Unit(
        identifier: $0.definition.canonicalIdentifier, symbol: $0.definition.symbol,
        aliases: $0.aliases,
        dimension: $0.definition.dimension.canonicalDescription)
    }
    // The examples are checked with this build's parser and engine.
    examples =
      ["200 + 10%", "(2400 INR + 10%) / 4", "6% / 12", "2024-02-29 + 1 year"]
      .compactMap { source in
        guard case .value(let value) = engine.evaluate(source, context: context) else { return nil }
        return Example(source: source, result: AssistanceValue(value))
      }
      + ["base = 40\nbase + 2", "40\n@1 + 2"].compactMap { source in
        var calculator = SheetCalculator(engine: engine)
        guard let evaluation = try? calculator.evaluate(SheetSource(source), context: context),
          case .value(let value) = evaluation.lines.last?.result
        else { return nil }
        return Example(source: source, result: AssistanceValue(value))
      }
  }
}
