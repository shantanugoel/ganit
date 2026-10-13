import Foundation
import GanitSuggestionProtocol

/// All output lines share original evidence. A derived line never grants new inputs.
struct AssistanceProposalPlan {
  let shadow: SheetSource
  let expression: Expression
  let facts: AssistanceExpressionFacts
  let locals: [AssistanceSymbol]
  let variableBindings: [String: String]
  let referenceNumbers: [Int: LineID]
  let resultLine: LineID
  let outputLines: Set<LineID>
  let referenceMapping: [Int: Int]
  let referenceChoices: [AssistanceChoice]
  let referenceOptions: [String: Set<String>]

  init(_ candidate: SuggestionCandidate, snapshot: AssistanceSnapshot, choices: [String: String])
    throws
  {
    let text = candidate.edits[0].replacement
    let source = SheetSource(text)
    guard !text.isEmpty, text.utf8.count <= SuggestionLimits.replacementBytes,
      source.lines.count <= SuggestionLimits.replacementLines
    else {
      throw AssistanceValidationFailure(
        .invalidBounds, "Use bounded calculation working for this target.")
    }
    for line in source.lines {
      guard case .calculation(_, let name, .some, _) = LineSyntax(line.text) else {
        throw AssistanceValidationFailure(
          .unsupportedOperation, "Each proposed line must contain a calculation.")
      }
      if let name, let declared = name.text(in: line.text),
        snapshot.scope.engine.variableName(in: String(declared), context: snapshot.context) == nil
      {
        throw AssistanceValidationFailure(
          .unsupportedOperation, "A proposal cannot add a unit, rate, or function definition.")
      }
    }
    try Self.preserveDeclarations(snapshot.targetLines, replacements: source.lines)
    var shadow = snapshot.source
    shadow.replace(utf8Range: snapshot.targetRange, with: text)
    let start = snapshot.source.lines.firstIndex { $0.id == snapshot.target.id }!
    let outputs = Array(shadow.lines[start..<(start + source.lines.count)])
    let originalText = snapshot.source.text
    let lower = originalText.utf8.index(
      originalText.utf8.startIndex, offsetBy: snapshot.targetRange.lowerBound)
    let upper = originalText.utf8.index(
      originalText.utf8.startIndex, offsetBy: snapshot.targetRange.upperBound)
    let changes = [NSRange(lower..<upper, in: originalText)]
    let effects = LineReferenceRenumbering.effects(
      replacing: changes, in: originalText,
      with: [text], configuration: snapshot.context.lexingConfiguration)
    var mapping: [Int: Int] = [:]
    var required: [AssistanceChoice] = []
    var options: [String: Set<String>] = [:]
    let selectedIDs = Set(snapshot.targetLines.map(\.id))
    for number in effects.ambiguousTargets.sorted()
    where selectedIDs.contains(snapshot.source.lines[number - 1].id) {
      let id = "reference_" + String(snapshot.source.lines[number - 1].id.rawValue)
      let offered = source.lines.enumerated().map { index, line in
        AssistanceChoice.Option(id: "line_\(index + 1)", title: "Line \(index + 1): " + line.text)
      }
      options[id] = Set(offered.map(\.id))
      if let chosen = choices[id] {
        guard let row = Int(chosen.dropFirst("line_".count)),
          offered.contains(where: { $0.id == chosen })
        else {
          throw AssistanceValidationFailure(.relation, "Select a supplied reference result.")
        }
        mapping[number] = start + row
      } else {
        // This is a provisional preview only. Apply stays blocked by the choice.
        mapping[number] = start + source.lines.count
        required.append(
          AssistanceChoice(
            id: id,
            question: "Which new result must the existing reference to line \(number) read?",
            options: offered))
      }
    }
    referenceMapping = mapping
    referenceChoices = required
    referenceOptions = options
    var calculator = snapshot.calculator
    let context = snapshot.context.with(assistantAnswers: [:])
    var locals: [AssistanceSymbol] = []
    var references: [Int: LineID] = [:]
    var allFacts: AssistanceExpressionFacts?
    var expressions: [String: Expression] = [:]
    var expressionSizes: [String: Int] = [:]
    var final: Expression?
    var resolutions: [String: String] = [:]
    for (index, line) in outputs.enumerated() {
      try Task.checkCancellation()
      let scope = try calculator.assistanceSnapshot(shadow, context: context, target: line.id)
      guard case .calculation(_, let name, let range?, _) = LineSyntax(line.text),
        let value = range.text(in: line.text)
      else { preconditionFailure("Checked calculation syntax") }
      let offset = source.lines[index].range.lowerBound
      let parsed = scope.scope.engine.parse(
        String(value), context: context,
        origin: SourceLocation(
          utf8Offset: offset + range.lowerBound,
          graphemeOffset: source.lines[index].range.graphemeLowerBound + range.graphemeLowerBound),
        variables: scope.scope.names.mapValues { $0?.kind ?? .number })
      guard let expression = parsed.expression else {
        throw AssistanceValidationFailure(
          .syntax, "The proposed working does not parse.",
          ranges: parsed.diagnostics.map(\.range), engineResult: .syntaxFailure(parsed.diagnostics))
      }
      let facts = AssistanceExpressionFacts(
        expression, source: text, engine: scope.scope.engine, context: context)
      for identifier in facts.identifiers {
        let record: AssistanceSymbol?
        if let origin = scope.scope.origins[identifier],
          let local = locals.last(where: { $0.declaration?.id == origin.id })
        {
          record = local
        } else {
          record = snapshot.inventory.first { $0.kind == "variable" && $0.name == identifier }
        }
        if let record {
          if let old = resolutions[identifier], old != record.handle {
            throw AssistanceValidationFailure(
              .unknownBinding, "One name reads two different declarations. Use distinct names.")
          }
          resolutions[identifier] = record.handle
          guard
            candidate.bindings.contains(where: {
              $0.symbol.lowercased() == identifier && $0.source == record.handle
            })
          else {
            throw AssistanceValidationFailure(
              .unknownBinding, "The working must bind to its actual declaration: " + identifier)
          }
        }
      }
      for reference in facts.references {
        for number in scope.scope.outcomes.lineNumbers(for: reference) ?? []
        where shadow.lines.indices.contains(number - 1) {
          references[number] = shadow.lines[number - 1].id
        }
      }
      if allFacts == nil { allFacts = facts } else { allFacts!.include(facts) }
      var operations = 0
      let expanded = try Self.expand(
        expression, locals: expressions, sizes: expressionSizes, operations: &operations)
      try Self.checkExpandedDepth(expanded)
      final = expanded
      let rawName = name?.text(in: line.text).map(String.init)
      if let rawName {
        expressions[rawName.lowercased()] = expanded
        expressionSizes[rawName.lowercased()] = operations
      }
      let result = scope.evaluation.lines.first { $0.id == line.id }
      let nativeValue: EngineValue?
      if case .value(let value) = result?.result { nativeValue = value } else { nativeValue = nil }
      locals.append(
        AssistanceSymbol(
          handle: "L\(index + 1)", name: rawName?.lowercased() ?? "@\(start + index + 1)",
          declaration: line, value: nativeValue, matchesTarget: true,
          kind: rawName == nil ? "line_result" : "variable",
          unreviewed: result?.hasUnreviewedModelDependency == true))
    }
    // Structural identities can span derived declarations. Their source ranges
    // still point to the same literal in the submitted working.
    let structural = AssistanceExpressionFacts(
      final!, source: text, engine: snapshot.scope.engine, context: context)
    let rules = Dictionary(
      structural.literals.compactMap { item in item.structuralRule.map { (item.range, $0) } },
      uniquingKeysWith: { first, _ in first })
    var facts = allFacts!
    facts.resourceLimited = facts.resourceLimited || structural.resourceLimited
    facts.literals = facts.literals.map { item in
      .init(
        source: item.source, value: item.value, range: item.range,
        structuralRule: rules[item.range] ?? item.structuralRule)
    }
    self.shadow = shadow
    self.expression = final!
    self.facts = facts
    self.locals = locals
    variableBindings = resolutions
    referenceNumbers = references
    resultLine = outputs.last!.id
    outputLines = Set(outputs.map(\.id))
  }

  private static func preserveDeclarations(_ originals: [SheetLine], replacements: [SheetLine])
    throws
  {
    for original in originals {
      guard case .calculation(let label, let name, _, let comment) = LineSyntax(original.text)
      else { continue }
      let fields = [label, name, comment].map { $0?.text(in: original.text).map(String.init) }
      guard fields.contains(where: { $0 != nil }) else { continue }
      let matching = replacements.filter { line in
        guard
          case .calculation(let nextLabel, let nextName, _, let nextComment) = LineSyntax(line.text)
        else { return false }
        return zip(fields, [nextLabel, nextName, nextComment]).allSatisfy { before, after in
          before == nil || before == after?.text(in: line.text).map(String.init)
        }
      }
      guard matching.count == 1 else {
        throw AssistanceValidationFailure(
          .changedDeclaration, "Keep each existing label, name, and comment exactly once.")
      }
    }
  }

  private static func checkExpandedDepth(_ expression: Expression) throws {
    var pending: [(Expression, Int)] = [(expression, 1)]
    while let (node, depth) = pending.popLast() {
      try Task.checkCancellation()
      guard depth <= SyntaxLimits.default.maximumParseDepth else {
        throw AssistanceValidationFailure(
          .evaluation, "The expanded working exceeds the native depth limit.",
          engineResult: .evaluationFailure(EngineError(code: .resourceLimitExceeded)))
      }
      switch node {
      case .prefix(_, let value, _, _), .percentage(let value, _, _),
        .quantity(let value, _, _), .period(let value, _, _), .relative(let value, _, _),
        .zoneConversion(let value, _, _), .money(let value, _, _),
        .currencyConversion(let value, _, _), .conversion(let value, _, _, _),
        .grouped(let value, _):
        pending.append((value, depth + 1))
      case .infix(let left, _, let right, _, _),
        .percentageOperation(_, let left, let right, _, _):
        pending.append((left, depth + 1))
        pending.append((right, depth + 1))
      case .call(_, _, let arguments, _):
        pending.append(contentsOf: arguments.map { ($0, depth + 1) })
      case .assistantPrompt(let parts, _, _):
        for case .placeholder(let value) in parts { pending.append((value, depth + 1)) }
      case .literal, .temporal, .identifier, .reference: break
      }
    }
  }

  private static func expand(
    _ node: Expression, locals: [String: Expression], sizes: [String: Int], operations: inout Int
  ) throws -> Expression {
    try Task.checkCancellation()
    operations += 1
    guard operations <= EvaluationLimits().maximumOperations else {
      throw AssistanceValidationFailure(
        .evaluation, "The working exceeds the native operation limit.",
        engineResult: .evaluationFailure(EngineError(code: .resourceLimitExceeded)))
    }
    switch node {
    case .identifier(let name, _):
      if let value = locals[name.lowercased()] {
        operations += (sizes[name.lowercased()] ?? 1) - 1
        guard operations <= EvaluationLimits.default.maximumOperations else {
          throw AssistanceValidationFailure(
            .evaluation, "The expanded working exceeds the native operation limit.",
            engineResult: .evaluationFailure(EngineError(code: .resourceLimitExceeded)))
        }
        return value
      }
      return node
    case .prefix(let op, let value, let operatorRange, let range):
      return .prefix(
        op, operand: try expand(value, locals: locals, sizes: sizes, operations: &operations),
        operatorRange: operatorRange, range: range)
    case .infix(let a, let op, let b, let operatorRange, let range):
      return .infix(
        left: try expand(a, locals: locals, sizes: sizes, operations: &operations), operator: op,
        right: try expand(b, locals: locals, sizes: sizes, operations: &operations),
        operatorRange: operatorRange,
        range: range)
    case .call(let name, let nameRange, let values, let range):
      var arguments: [Expression] = []
      for value in values {
        arguments.append(try expand(value, locals: locals, sizes: sizes, operations: &operations))
      }
      return .call(name: name, nameRange: nameRange, arguments: arguments, range: range)
    case .grouped(let value, let range):
      return .grouped(
        try expand(value, locals: locals, sizes: sizes, operations: &operations), range: range)
    case .percentage(let value, let percentRange, let range):
      return .percentage(
        points: try expand(value, locals: locals, sizes: sizes, operations: &operations),
        percentRange: percentRange, range: range)
    case .percentageOperation(let op, let a, let b, let operatorRange, let range):
      return .percentageOperation(
        operator: op, left: try expand(a, locals: locals, sizes: sizes, operations: &operations),
        right: try expand(b, locals: locals, sizes: sizes, operations: &operations),
        operatorRange: operatorRange,
        range: range)
    case .money(let value, let currency, let range):
      return .money(
        amount: try expand(value, locals: locals, sizes: sizes, operations: &operations),
        currency: currency,
        range: range)
    case .quantity(let value, let unit, let range):
      return .quantity(
        magnitude: try expand(value, locals: locals, sizes: sizes, operations: &operations),
        unit: unit,
        range: range)
    case .conversion(let value, let unit, let keyword, let range):
      return .conversion(
        value: try expand(value, locals: locals, sizes: sizes, operations: &operations),
        target: unit,
        keywordRange: keyword, range: range)
    case .currencyConversion(let value, let currency, let range):
      return .currencyConversion(
        value: try expand(value, locals: locals, sizes: sizes, operations: &operations),
        currency: currency,
        range: range)
    case .zoneConversion(let value, let zone, let range):
      return .zoneConversion(
        value: try expand(value, locals: locals, sizes: sizes, operations: &operations), zone: zone,
        range: range)
    case .period(let value, let unit, let range):
      return .period(
        count: try expand(value, locals: locals, sizes: sizes, operations: &operations), unit: unit,
        range: range)
    case .relative(let value, let isPast, let range):
      return .relative(
        offset: try expand(value, locals: locals, sizes: sizes, operations: &operations),
        isPast: isPast,
        range: range)
    default: return node
    }
  }
}
