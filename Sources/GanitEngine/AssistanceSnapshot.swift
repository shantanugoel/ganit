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
  public let targetLines: [SheetLine]
  public var targetRange: Range<Int> {
    targetLines[0].range.lowerBound..<targetLines[targetLines.count - 1].range.upperBound
  }
  public let targetText: String
  public let evaluation: SheetEvaluation
  public private(set) var inventory: [AssistanceSymbol]
  public private(set) var notes: [AssistanceNote]
  package let scope: AssistanceScope
  package let calculator: SheetCalculator

  package init(
    source: SheetSource, context: EvaluationContext, target: SheetLine,
    evaluation: SheetEvaluation, scope: AssistanceScope, calculator: SheetCalculator,
    targetLines: [SheetLine]? = nil
  ) {
    self.source = source
    self.context = context
    self.target = target
    let selected = targetLines ?? [target]
    self.targetLines = selected
    self.targetText = selected.enumerated().map { index, line in
      line.text + (index == selected.count - 1 ? "" : line.terminator?.rawValue ?? "\n")
    }.joined()
    self.evaluation = evaluation
    self.scope = scope
    self.calculator = calculator
    let targetIndex = source.lines.firstIndex { $0.id == target.id }!
    var originalReferences: Set<LineReference> = []
    for line in self.targetLines {
      if case .calculation(_, _, let range?, _) = LineSyntax(line.text),
        let text = range.text(in: line.text)
      {
        originalReferences.formUnion(
          scope.engine.parse(
            String(text), context: context,
            variables: scope.names.mapValues { $0?.kind ?? .number }
          ).expression?.references ?? [])
      }
    }
    let selectedNames = SheetCalculator.assistanceMatches(
      in: self.targetText, scope: scope, context: context)
    let referenced = Set(
      originalReferences.flatMap { scope.outcomes.lineNumbers(for: $0) ?? [] }.map {
        source.lines[$0 - 1].id
      })
    var symbols = scope.names.keys.sorted().enumerated().map { index, name in
      AssistanceSymbol(
        handle: "S\(index + 1)", name: name, declaration: scope.origins[name],
        value: scope.names[name] ?? nil,
        matchesTarget: scope.matches.contains(name) || selectedNames.contains(name)
          || scope.origins[name].map { referenced.contains($0.id) } == true,
        kind: "variable", unreviewed: scope.unreviewedNames.contains(name))
    }
    var resultCount = 0
    for (index, pair) in zip(source.lines[..<targetIndex], evaluation.lines[..<targetIndex])
      .enumerated()
    {
      let (line, result) = pair
      guard !symbols.contains(where: { $0.declaration?.id == line.id }), let outcome = result.result
      else { continue }
      let value: EngineValue?
      if case .value(let found) = outcome { value = found } else { value = nil }
      resultCount += 1
      symbols.append(
        AssistanceSymbol(
          handle: "R\(resultCount)", name: "@\(index + 1)",
          declaration: line, value: value, matchesTarget: referenced.contains(line.id),
          kind: "line_result", unreviewed: result.hasUnreviewedModelDependency))
    }
    for (index, name) in scope.functions.keys.sorted().enumerated() {
      let function = scope.functions[name]!
      symbols.append(
        AssistanceSymbol(
          handle: "F\(index + 1)", name: name,
          declaration: nil, value: nil,
          matchesTarget: scope.functionMatches.contains(name) || selectedNames.contains(name),
          kind: "function", unreviewed: function.hasUnreviewedCapture, function: function))
    }
    inventory = symbols
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

  /// False when every target line is blank and the reader typed no words, so
  /// an Ask would send the model nothing to work on.
  public var hasRequest: Bool {
    targetLines.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
      || notes.contains { $0.source.hasPrefix("// Task: ") }
  }

  /// An explicit user answer supplies a task constraint for a new job.
  public func addingTaskNote(_ text: String) throws -> AssistanceSnapshot {
    guard text.utf8.count <= SuggestionLimits.targetBytes,
      !text.contains("\n"), !text.contains("\r")
    else { throw AssistanceSnapshotError.contextTooLarge }
    var copy = self
    copy.notes.append(AssistanceNote(source: "// Task: " + text))
    let matches = SheetCalculator.assistanceMatches(in: text, scope: scope, context: context)
    let references = taskReferences(in: text)
    copy.inventory = inventory.map { symbol in
      AssistanceSymbol(
        handle: symbol.handle, name: symbol.name, declaration: symbol.declaration,
        value: symbol.value,
        matchesTarget: symbol.matchesTarget || matches.contains(symbol.name)
          || symbol.declaration.map { references.contains($0.id) } == true,
        kind: symbol.kind, unreviewed: symbol.unreviewed, function: symbol.function)
    }
    _ = try copy.permittedContext()
    return copy
  }

  private func taskReferences(in text: String) -> Set<LineID> {
    let tokens = Lexer(source: text, configuration: context.lexingConfiguration).lex().tokens
    var references: Set<LineReference> = []
    for (word, number) in zip(tokens, tokens.dropFirst()) {
      guard word.kind == .at || word.kind == .identifier("line"),
        case .number = number.kind,
        let source = word.range.union(number.range).text(in: text),
        let reference = scope.engine.assistanceReference(
          in: String(source), context: context,
          variables: scope.names.mapValues { $0?.kind ?? .number })
      else { continue }
      references.insert(reference)
    }
    return Set(
      references.flatMap { scope.outcomes.lineNumbers(for: $0) ?? [] }.map {
        source.lines[$0 - 1].id
      })
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
    let evidence = evidence(including: handles)
    let diagnostics = targetLines.flatMap { line in
      AssistanceDiagnostic.records(
        evaluation.lines.first { $0.id == line.id }?.result,
        origin: SourceLocation(
          utf8Offset: line.range.lowerBound - target.range.lowerBound,
          graphemeOffset: line.range.graphemeLowerBound - target.range.graphemeLowerBound))
    }
    let catalog = scope.engine.assistanceCatalog(
      for: targetText + "\n" + notes.map(\.source).joined(separator: "\n"), context: context)
    var originHandles: [String: String] = [:]
    func opaqueOrigin(_ native: String) -> String {
      let suffix = ":\(source.assistanceIdentity.uuidString):line:"
      let origin =
        native.hasPrefix("sheet" + suffix) || native.hasPrefix("definitions" + suffix)
        ? "line:" + native.components(separatedBy: suffix).last! : native
      if let handle = originHandles[origin] { return handle }
      let handle = "source:\(originHandles.count + 1)"
      originHandles[origin] = handle
      return handle
    }
    let encodedSymbols = try symbols.map {
      try SymbolRecord($0, engine: scope.engine, context: context, originKey: opaqueOrigin)
    }
    let dependencySources = try dependencySources(for: symbols).map {
      DependencySource(origin: opaqueOrigin($0.origin), source: $0.source)
    }
    guard
      encodedSymbols.reduce(0, { $0 + $1.recordCount }) + dependencySources.count
        <= SuggestionLimits.symbols
    else {
      throw AssistanceSnapshotError.contextTooLarge
    }
    let records = ContextRecords(
      notes: notes, symbols: encodedSymbols, settings: SettingsRecord(context),
      evidence: evidence, catalog: catalog, diagnostics: diagnostics,
      dependencySources: dependencySources)
    guard try encoder.encode(records).count <= SuggestionLimits.contextBytes else {
      throw AssistanceSnapshotError.contextTooLarge
    }
    let data = try encoder.encode(
      PermittedContext(
        target: TargetRecord(handle: "T1", source: targetText), notes: notes,
        symbols: encodedSymbols, settings: SettingsRecord(context),
        evidence: evidence, catalog: catalog, diagnostics: diagnostics,
        dependencySources: dependencySources))
    guard data.count <= SuggestionLimits.requestBytes else {
      throw AssistanceSnapshotError.contextTooLarge
    }
    return data
  }

  private struct DependencySource: Encodable {
    let origin: String
    let source: String
  }

  /// Read dependencies from each line's native scope, before later redeclarations.
  private func dependencySources(for symbols: [AssistanceSymbol]) throws -> [DependencySource] {
    var tracer = calculator
    let targets = Set(targetLines.map(\.id))
    let disclosed = Set(symbols.compactMap { $0.declaration?.id })
    var pending = targetLines.map(\.id) + symbols.compactMap { $0.declaration?.id }
    var visited: Set<LineID> = []
    var functionLines: Set<LineID> = []
    var records: [DependencySource] = []
    var origins: Set<String> = []
    func append(_ origin: String, _ text: String) throws {
      guard origins.insert(origin).inserted else { return }
      records.append(DependencySource(origin: origin, source: text))
      guard records.count <= SuggestionLimits.symbols,
        records.reduce(0, { $0 + $1.source.utf8.count }) <= SuggestionLimits.contextBytes
      else { throw AssistanceSnapshotError.contextTooLarge }
    }
    func includeFunction(_ function: CustomFunction) throws {
      let closure = try AssistanceFunctionContext(function, engine: scope.engine, context: context)
      for definition in closure.definitions {
        if let origin = closure.origins.first(where: { $0.identifier == definition.origin }),
          origin.document == source.assistanceIdentity
        {
          functionLines.insert(origin.line)
        }
      }
      for origin in closure.origins {
        if origin.document == source.assistanceIdentity {
          pending.append(origin.line)
        } else {
          try append(origin.identifier, origin.source)
        }
      }
    }
    for symbol in symbols {
      if let function = symbol.function, !symbol.unreviewed { try includeFunction(function) }
    }
    var position = 0
    while position < pending.count {
      try Task.checkCancellation()
      let id = pending[position]
      position += 1
      guard visited.insert(id).inserted,
        let line = source.lines.first(where: { $0.id == id })
      else { continue }
      if !targets.contains(id), !disclosed.contains(id) {
        try append("line:\(id.rawValue)", line.text)
      }
      if functionLines.contains(id) { continue }
      let native = try tracer.assistanceSnapshot(source, context: context, target: id)
      var reads: Set<String>?
      if case .calculation(_, _, let range?, _) = LineSyntax(line.text),
        let text = range.text(in: line.text),
        let expression = native.scope.engine.parse(
          String(text), context: context,
          variables: native.scope.names.mapValues { $0?.kind ?? .number }
        ).expression
      {
        let facts = AssistanceExpressionFacts(
          expression, source: String(text), engine: native.scope.engine, context: context)
        reads = facts.identifiers.union(facts.calls)
        let references = Set(
          expression.references.flatMap {
            native.scope.outcomes.lineNumbers(for: $0) ?? []
          }.map { source.lines[$0 - 1].id })
        for line in source.lines where references.contains(line.id) { pending.append(line.id) }
      }
      for symbol in native.inventory
      where symbol.matchesTarget
        && (reads == nil || reads!.contains(symbol.name))
      {
        if let declaration = symbol.declaration { pending.append(declaration.id) }
        if let function = symbol.function, !symbol.unreviewed { try includeFunction(function) }
      }
    }
    return records
  }

  private struct TargetRecord: Encodable {
    let handle: String
    let source: String
  }
  private struct SymbolRecord: Encodable {
    let handle: String
    let name: String
    let kind: String
    let source: String?
    let origin: String
    let value: AssistanceValue?
    let unavailable: Bool
    let unreviewed: Bool
    let function: AssistanceFunctionContext?
    var recordCount: Int { 1 + (function?.recordCount ?? 0) }

    init(
      _ symbol: AssistanceSymbol, engine: CalculationEngine, context: EvaluationContext,
      originKey: (String) -> String
    ) throws {
      handle = symbol.handle
      name = symbol.name
      kind = symbol.kind
      source = symbol.sourceText
      origin = originKey(
        symbol.function?.assistanceOrigin?.identifier
          ?? symbol.declaration.map { "line:\($0.id.rawValue)" } ?? "definitions")
      unreviewed = symbol.unreviewed
      value = symbol.unreviewed ? nil : symbol.value.map(AssistanceValue.init)
      function =
        try symbol.unreviewed
        ? nil
        : symbol.function.map {
          try AssistanceFunctionContext($0, engine: engine, context: context, originKey: originKey)
        }
      unavailable = (symbol.value == nil && function == nil) || symbol.unreviewed
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
    let evidence: [AssistanceEvidence]
    let catalog: AssistanceCatalog
    let diagnostics: [AssistanceDiagnostic]
    let dependencySources: [DependencySource]
  }
  private struct PermittedContext: Encodable {
    let target: TargetRecord
    let notes: [AssistanceNote]
    let symbols: [SymbolRecord]
    let settings: SettingsRecord
    let evidence: [AssistanceEvidence]
    let catalog: AssistanceCatalog
    let diagnostics: [AssistanceDiagnostic]
    let dependencySources: [DependencySource]
  }
}

public struct AssistanceSymbol: Sendable {
  public let handle: String
  public let name: String
  public let declaration: SheetLine?
  public let value: EngineValue?
  public let matchesTarget: Bool
  public let kind: String
  public let unreviewed: Bool
  package var function: CustomFunction? = nil
  public var sourceText: String? { declaration?.text ?? function?.assistanceOrigin?.source }
}

public struct AssistanceNote: Encodable, Sendable {
  public let source: String
  public var historical: Bool {
    let text = source.trimmingCharacters(in: .whitespaces)
    return ["// Request record:", "// Task record:", "// Approved assumption:"].contains {
      text.hasPrefix($0)
    }
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
  let functionMatches: Set<String>
  let unreviewedNames: Set<String>
  let unreviewedUnits: Set<String>
}

extension CalculationEngine {
  /// A task sentence can end immediately after an explicit reference.
  package func assistanceReference(
    in source: String, context: EvaluationContext,
    variables: [String: EngineValueKind]
  ) -> LineReference? {
    let fragment = source.hasSuffix(".") ? String(source.dropLast()) : source
    guard
      case .reference(let reference, _) = parse(
        fragment, context: context,
        variables: variables
      ).expression
    else { return nil }
    return reference
  }
}
