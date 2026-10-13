import Foundation
import GanitSuggestionProtocol

public enum AssistanceSnapshotError: Error, Equatable, Sendable {
  case unknownTarget
  case targetTooLarge
  case unsupportedTarget
  case contextTooLarge
}

/// The immutable local sheet and native scope for one suggestion target.
/// Only `permittedContext` can be encoded for a provider.
public struct AssistanceSnapshot: Sendable {
  public let source: SheetSource
  public let context: EvaluationContext
  public let target: SheetLine
  public let evaluation: SheetEvaluation
  public let inventory: [AssistanceSymbol]
  public let notes: [AssistanceNote]
  package let scope: AssistanceScope
  package let calculator: SheetCalculator

  package init(
    source: SheetSource, context: EvaluationContext, target: SheetLine,
    evaluation: SheetEvaluation, scope: AssistanceScope, calculator: SheetCalculator
  ) {
    self.source = source
    self.context = context
    self.target = target
    self.evaluation = evaluation
    self.scope = scope
    self.calculator = calculator
    inventory = scope.names.keys.sorted().enumerated().map { index, name in
      AssistanceSymbol(
        handle: "S\(index + 1)", name: name, declaration: scope.origins[name],
        value: scope.names[name] ?? nil, matchesTarget: scope.matches.contains(name))
    }
    let targetIndex = source.lines.firstIndex { $0.id == target.id }!
    var attached: [AssistanceNote] = []
    for line in source.lines[..<targetIndex].reversed() {
      guard case .comment = LineSyntax(line.text) else { break }
      attached.insert(AssistanceNote(source: line.text), at: 0)
    }
    if let heading = source.lines[..<targetIndex].last(where: {
      if case .heading = LineSyntax($0.text) { return true }
      return false
    }) {
      attached.insert(AssistanceNote(source: heading.text), at: 0)
    }
    notes = attached
  }

  /// Additional handles need permission from the coordinator before this call.
  /// Encoding never includes the local shadow sheet or the unselected inventory.
  public func permittedContext(including handles: Set<String> = []) throws -> Data {
    guard handles.isSubset(of: Set(inventory.map(\.handle))) else {
      throw AssistanceSnapshotError.unknownTarget
    }
    let symbols = inventory.filter { $0.matchesTarget || handles.contains($0.handle) }
    guard symbols.count <= SuggestionLimits.symbols else {
      throw AssistanceSnapshotError.contextTooLarge
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let records = ContextRecords(
      notes: notes, symbols: symbols.map(SymbolRecord.init), settings: SettingsRecord(context))
    guard try encoder.encode(records).count <= SuggestionLimits.contextBytes else {
      throw AssistanceSnapshotError.contextTooLarge
    }
    let data = try encoder.encode(
      PermittedContext(
        target: TargetRecord(handle: "T1", source: target.text), notes: notes,
        symbols: symbols.map(SymbolRecord.init), settings: SettingsRecord(context)))
    guard data.count <= SuggestionLimits.requestBytes else {
      throw AssistanceSnapshotError.contextTooLarge
    }
    return data
  }

  private struct TargetRecord: Encodable {
    let handle: String
    let source: String
  }
  private struct SymbolRecord: Encodable {
    let handle: String
    let name: String
    let source: String?
    let origin: String
    let value: AssistanceValue?
    let unavailable: Bool

    init(_ symbol: AssistanceSymbol) {
      handle = symbol.handle
      name = symbol.name
      source = symbol.declaration?.text
      origin = symbol.declaration.map { "line:\($0.id.rawValue)" } ?? "definitions"
      value = symbol.value.map(AssistanceValue.init)
      unavailable = symbol.value == nil
    }
  }
  private struct SettingsRecord: Encodable {
    let locale: String
    let decimalSeparator: String
    let groupingSeparator: String?
    let primaryGroupingSize: Int
    let secondaryGroupingSize: Int
    let angleMode: String
    let precision: Int
    let rounding: String
    let now: Double
    let calendar: String
    let timeZone: String
    let dollarCurrency: String
    let markdown: Bool
    let ambiguousSuffixes: [String: String]

    init(_ context: EvaluationContext) {
      locale = context.localeIdentifier
      decimalSeparator = String(context.lexingConfiguration.decimalSeparator)
      groupingSeparator = context.lexingConfiguration.groupingSeparator.map(String.init)
      primaryGroupingSize = context.lexingConfiguration.primaryGroupingSize
      secondaryGroupingSize = context.lexingConfiguration.secondaryGroupingSize
      angleMode = context.angleMode.rawValue
      precision = context.precision.significantDecimalDigits
      rounding = context.precision.roundingRule.rawValue
      now = context.now.timeIntervalSince1970
      calendar = String(describing: context.calendarIdentifier)
      timeZone = context.timeZoneIdentifier
      dollarCurrency = context.dollarCurrency
      markdown = context.isMarkdownMode
      ambiguousSuffixes = context.ambiguousSuffixes.mapValues(\.rawValue)
    }
  }
  private struct ContextRecords: Encodable {
    let notes: [AssistanceNote]
    let symbols: [SymbolRecord]
    let settings: SettingsRecord
  }
  private struct PermittedContext: Encodable {
    let target: TargetRecord
    let notes: [AssistanceNote]
    let symbols: [SymbolRecord]
    let settings: SettingsRecord
  }
}

public struct AssistanceSymbol: Sendable {
  public let handle: String
  public let name: String
  public let declaration: SheetLine?
  public let value: EngineValue?
  public let matchesTarget: Bool
}

public struct AssistanceNote: Encodable, Sendable {
  public let source: String
  public var historical: Bool {
    source.trimmingCharacters(in: .whitespaces).hasPrefix("// Request record:")
  }

  public func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: Key.self)
    try fields.encode(source, forKey: .source)
    try fields.encode(historical, forKey: .historical)
  }
  private enum Key: String, CodingKey { case source, historical }
}

/// Captured directly from the normal engine fold, before the target declares a name.
package struct AssistanceScope: Sendable {
  let engine: CalculationEngine
  let names: [String: EngineValue?]
  let functions: [String: CustomFunction]
  let rates: [CurrencyPair: NumericValue]
  let outcomes: LineOutcomes
  let origins: [String: SheetLine]
  let matches: Set<String>
}
