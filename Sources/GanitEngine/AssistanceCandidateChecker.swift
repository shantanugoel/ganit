import Foundation
import GanitSuggestionProtocol

public struct AssistanceValidationFailure: Error, Sendable {
  public enum Code: String, Sendable {
    case invalidBounds, unauthorizedEdit, changedDeclaration, unknownBinding, missingEvidence
    case unsupportedOperation, syntax, evaluation, dimension, relation, downstreamFailure
  }
  public let code: Code
  public let message: String
  public let ranges: [SourceRange]
  public let engineResult: CalculationResult?

  init(
    _ code: Code, _ message: String, ranges: [SourceRange] = [],
    engineResult: CalculationResult? = nil
  ) {
    self.code = code
    self.message = message
    self.ranges = ranges
    self.engineResult = engineResult
  }
}

public struct AssistanceCheckedCandidate: Sendable {
  public let candidate: SuggestionCandidate
  public let result: EngineValue
  public let evaluation: SheetEvaluation
  public let choices: [AssistanceChoice]
  public let interpretation: String
  public let referencedLineIDs: [LineID]
  public let changedResults: [LineID]
  public let sourceBefore: String
  public let sourceAfter: String
  public let rateUses: Set<CurrencyRateUse>
  public let requiresAssumptionApproval: Bool
  public let readsClock: Bool
  package let patches: [TableSourcePatch]

  public var isApplicable: Bool { choices.isEmpty && !requiresAssumptionApproval }
}

public enum AssistanceCandidateChecker {
  public static func check(
    _ candidate: SuggestionCandidate, against snapshot: AssistanceSnapshot,
    permittedHandles: Set<String> = [], selectedChoices: [String: String] = [:],
    approvedAssumptions: Set<String> = [], userRevisedInputs: Bool = false
  ) throws -> AssistanceCheckedCandidate {
    try Task.checkCancellation()
    guard candidate.edits.count == 1, candidate.edits[0].target == "T1" else {
      throw AssistanceValidationFailure(
        .unauthorizedEdit, "The proposal does not match the permitted target.")
    }
    let originalResult = snapshot.evaluation.lines.first { $0.id == snapshot.target.id }?.result
    if !userRevisedInputs, case .evaluationFailure(let error) = originalResult,
      [
        .divisionByZero, .invalidDomain, .invalidDate, .invalidTime, .nonexistentLocalTime,
        .ambiguousLocalTime, .dateOutOfRange, .missingCurrencyRate, .currencyRatesUnavailable,
        .resourceLimitExceeded,
      ].contains(error.code)
    {
      throw AssistanceValidationFailure(
        .evaluation,
        "The supplied inputs still have a native calculation error. Supply a revised input or constraint.",
        engineResult: originalResult)
    }
    let replacement = candidate.edits[0].replacement
    guard replacement.utf8.count <= SuggestionLimits.replacementBytes,
      !replacement.contains("\n"), !replacement.contains("\r"), !replacement.isEmpty
    else {
      throw AssistanceValidationFailure(
        .invalidBounds, "Use one bounded expression for this target.")
    }
    guard
      case .calculation(let label, let name, let expressionRange?, let comment) = LineSyntax(
        replacement),
      let expressionText = expressionRange.text(in: replacement)
    else {
      throw AssistanceValidationFailure(
        .unsupportedOperation, "The edit must contain a calculation.")
    }
    if let name, let declared = name.text(in: replacement),
      snapshot.scope.engine.variableName(in: String(declared), context: snapshot.context) == nil
    {
      throw AssistanceValidationFailure(
        .unsupportedOperation, "A proposal cannot add a unit, rate, or function definition.")
    }
    let original = LineSyntax(snapshot.target.text)
    if case .calculation(let oldLabel, let oldName, _, let oldComment) = original {
      for (before, after) in [(oldLabel, label), (oldName, name), (oldComment, comment)] {
        if let before, before.text(in: snapshot.target.text) != after?.text(in: replacement) {
          throw AssistanceValidationFailure(
            .changedDeclaration, "Keep the existing label, name, and comment.")
        }
      }
    }
    let variables = snapshot.scope.names.mapValues { $0?.kind ?? .number }
    let parsing = snapshot.scope.engine.parse(
      String(expressionText), context: snapshot.context,
      origin: SourceLocation(
        utf8Offset: expressionRange.lowerBound, graphemeOffset: expressionRange.graphemeLowerBound),
      variables: variables)
    guard let expression = parsing.expression else {
      throw AssistanceValidationFailure(
        .syntax, "The proposed expression does not parse.",
        ranges: parsing.diagnostics.map(\.range), engineResult: .syntaxFailure(parsing.diagnostics))
    }
    let facts = AssistanceExpressionFacts(
      expression, source: replacement, engine: snapshot.scope.engine, context: snapshot.context)
    guard !facts.containsAssistant,
      facts.unitIdentifiers.isDisjoint(with: snapshot.scope.unreviewedUnits)
    else {
      throw AssistanceValidationFailure(
        .unsupportedOperation, "A proposal cannot call ask_assistant.")
    }
    let permitted = snapshot.inventory.filter {
      $0.matchesTarget || permittedHandles.contains($0.handle)
    }
    guard permittedHandles.isSubset(of: Set(snapshot.inventory.map(\.handle))) else {
      throw AssistanceValidationFailure(.unknownBinding, "The context handle is not supplied.")
    }
    guard
      userRevisedInputs || !permitted.contains(where: { $0.kind == "variable" && $0.value == nil })
    else {
      throw AssistanceValidationFailure(
        .evaluation, "A required input is unavailable. Supply that input before calculating.",
        engineResult: originalResult)
    }
    let bindings = Dictionary(
      candidate.bindings.map { ($0.symbol.lowercased(), $0.source) },
      uniquingKeysWith: { first, _ in first })
    guard bindings.count == candidate.bindings.count else {
      throw AssistanceValidationFailure(.unknownBinding, "A symbol has more than one binding.")
    }
    for symbol in facts.identifiers {
      if let record = snapshot.inventory.first(where: { $0.name == symbol }) {
        guard !record.unreviewed, permitted.contains(where: { $0.handle == record.handle }),
          bindings[symbol] == record.handle
        else {
          throw AssistanceValidationFailure(
            .unknownBinding, "The symbol must bind to its permitted declaration: " + symbol)
        }
      } else if !["pi", "π", "e", "c"].contains(symbol) {
        throw AssistanceValidationFailure(.unknownBinding, "The symbol is not declared: " + symbol)
      }
    }
    let referenceNumbers = Set(
      facts.references.flatMap { snapshot.scope.outcomes.lineNumbers(for: $0) ?? [] })
    let referenceRecords = permitted.filter { record in
      record.declaration.map { declaration in
        referenceNumbers.contains { snapshot.source.lines[$0 - 1].id == declaration.id }
      } == true
    }
    let referenceBindings = Set(referenceNumbers.map { "@\($0)" } + referenceRecords.map(\.name))
    for binding in candidate.bindings where referenceBindings.contains(binding.symbol.lowercased())
    {
      guard
        referenceRecords.contains(where: { record in
          record.handle == binding.source
            && (record.name == binding.symbol.lowercased()
              || record.declaration.map { declaration in
                referenceNumbers.contains {
                  "@\($0)" == binding.symbol && snapshot.source.lines[$0 - 1].id == declaration.id
                }
              } == true)
        })
      else {
        throw AssistanceValidationFailure(
          .unknownBinding, "The reference binding does not match its source identity.")
      }
    }
    guard
      bindings.keys.allSatisfy({ facts.identifiers.contains($0) || referenceBindings.contains($0) })
    else {
      throw AssistanceValidationFailure(.unknownBinding, "A binding is not used by the expression.")
    }
    for name in facts.calls where snapshot.scope.functions[name] != nil {
      guard permitted.contains(where: { $0.kind == "function" && $0.name == name }) else {
        throw AssistanceValidationFailure(
          .unknownBinding, "The required function definition is not in the permitted context.")
      }
    }
    // Custom bodies are inspected locally. Their captured values cannot grant AI access.
    var functions = facts.calls.compactMap { snapshot.scope.functions[$0] }
    var visited: Set<CustomFunction> = []
    while let function = functions.popLast() {
      guard visited.insert(function).inserted else { continue }
      let body = AssistanceExpressionFacts(
        function.body, source: "", engine: snapshot.scope.engine, context: snapshot.context)
      guard !body.containsAssistant, !function.hasUnreviewedCapture else {
        throw AssistanceValidationFailure(
          .unsupportedOperation, "A required function calls ask_assistant.")
      }
      functions.append(contentsOf: body.calls.compactMap { function.functions[$0] })
    }
    let allowedChoices: [String: Set<String>] = [
      "profit_basis": ["cost", "sale"], "rate_period": ["nominal", "effective"],
      "tax_inclusion": ["included", "excluded"], "split_exclusions": ["exclude", "separate"],
      "date_order": ["day_month", "month_day"],
      "expected_dimension": ["proposed", "edit_request"],
    ]
    guard selectedChoices.allSatisfy({ allowedChoices[$0.key]?.contains($0.value) == true }) else {
      throw AssistanceValidationFailure(
        .relation, "The selected interpretation is not a supplied choice.")
    }
    let policy = AssistanceSemanticPolicy(snapshot: snapshot, choices: selectedChoices)
    let evidence = Dictionary(
      uniqueKeysWithValues: snapshot.evidence(including: permittedHandles).map { ($0.handle, $0) })
    for claim in candidate.literals {
      if claim.evidence.hasPrefix("K:") {
        guard
          ["K:identity", "K:profit_margin_identity", "K:nominal_months"].contains(claim.evidence),
          case .value(let claimed) = snapshot.scope.engine.evaluate(
            claim.text, context: snapshot.context),
          facts.literals.contains(where: { literal in
            guard assistanceLiteralValuesEqual(claimed, literal.value, context: snapshot.context)
            else {
              return false
            }
            if claim.evidence == "K:nominal_months" {
              return literal.structuralRule == "division_denominator" && policy.annualMonthly
                && assistanceLiteralValuesEqual(
                  claimed, .number(.integer(IntegerValue(12))), context: snapshot.context)
            }
            return literal.structuralRule != nil
              && assistanceLiteralValuesEqual(
                claimed, .number(.integer(IntegerValue(1))), context: snapshot.context)
          })
        else {
          throw AssistanceValidationFailure(
            .missingEvidence, "The structural constant is not permitted in this expression.")
        }
        continue
      }
      guard let record = evidence[claim.evidence], record.kind == "literal",
        let sourceValue = record.value,
        case .value(let claimValue) = snapshot.scope.engine.evaluate(
          claim.text, context: snapshot.context),
        assistanceLiteralValuesEqual(sourceValue, claimValue, context: snapshot.context),
        facts.literals.contains(where: {
          assistanceLiteralValuesEqual($0.value, claimValue, context: snapshot.context)
        })
      else {
        throw AssistanceValidationFailure(
          .missingEvidence, "A literal record has no matching parsed literal and source evidence.")
      }
    }
    for literal in facts.literals {
      var grounded = false
      for claim in candidate.literals {
        guard let record = evidence[claim.evidence], let value = record.value,
          record.kind == "literal",
          case .value(let claimed) = snapshot.scope.engine.evaluate(
            claim.text, context: snapshot.context),
          assistanceLiteralValuesEqual(claimed, literal.value, context: snapshot.context),
          assistanceLiteralValuesEqual(value, literal.value, context: snapshot.context)
        else { continue }
        grounded = true
      }
      if !grounded, let rule = literal.structuralRule {
        if rule == "identity" || rule == "division_denominator" || rule == "profit_margin_identity"
        {
          grounded =
            assistanceLiteralValuesEqual(
              literal.value, .number(.integer(IntegerValue(1))), context: snapshot.context)
            && (rule != "profit_margin_identity" || policy.profitBasis == "sale"
              || policy.needsProfitBasis)
        }
        if rule == "division_denominator",
          policy.nominalMonthly || (policy.annualMonthly && selectedChoices["rate_period"] == nil)
        {
          grounded =
            grounded
            || assistanceLiteralValuesEqual(
              literal.value, .number(.integer(IntegerValue(12))), context: snapshot.context)
        }
      }
      guard grounded else {
        throw AssistanceValidationFailure(
          .missingEvidence, "A numeric literal has no matching source evidence: " + literal.source,
          ranges: [literal.range])
      }
    }
    for temporal in facts.temporal {
      guard
        evidence.values.contains(where: { $0.kind == "temporal" && $0.temporal == temporal.literal }
        )
      else {
        throw AssistanceValidationFailure(
          .missingEvidence, "The date or time has no matching source evidence.",
          ranges: [temporal.range])
      }
    }
    guard
      facts.unitConstants.allSatisfy({ constant in
        [-3, -2, -1, 1, 2, 3].contains(constant)
          || evidence.values.contains(where: { record in
            record.value.map { value in
              assistanceValuesEqual(
                value, .number(.integer(IntegerValue(constant))), context: snapshot.context)
            } ?? false
          })
      })
    else {
      throw AssistanceValidationFailure(.missingEvidence, "A unit count needs source evidence.")
    }
    for relation in candidate.relations {
      guard !relation.rule.isEmpty, evidence[relation.evidence]?.kind == "relation" else {
        throw AssistanceValidationFailure(.relation, "A relation must cite supplied task text.")
      }
    }
    if !snapshot.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      candidate.relations.isEmpty
    {
      throw AssistanceValidationFailure(
        .relation, "Describe the interpretation with supplied task evidence.")
    }
    guard Set(candidate.assumptions.map(\.id)).count == candidate.assumptions.count,
      approvedAssumptions.isSubset(of: Set(candidate.assumptions.map(\.id))),
      candidate.assumptions.allSatisfy({ evidence[$0.evidence]?.kind == "relation" })
    else {
      throw AssistanceValidationFailure(
        .missingEvidence, "An assumption has no supplied task evidence.")
    }
    var shadow = snapshot.source
    shadow.replace(
      utf8Range: snapshot.target.range.lowerBound..<snapshot.target.range.upperBound,
      with: replacement)
    // Legacy model values are never evidence for a preview.
    let context = snapshot.context.with(assistantAnswers: [:])
    var calculator = snapshot.calculator
    let safeBaseline = try calculator.evaluate(snapshot.source, context: context)
    let evaluation = try calculator.evaluate(shadow, context: context)
    guard let line = evaluation.lines.first(where: { $0.id == snapshot.target.id }),
      case .value(let result) = line.result
    else {
      let failed = evaluation.lines.first(where: { $0.id == snapshot.target.id })?.result
      throw AssistanceValidationFailure(
        .evaluation, "The engine cannot calculate the proposed expression.", engineResult: failed)
    }
    if policy.expectedVolume {
      guard case .quantity(let quantity) = result,
        quantity.unit.dimension == (try Dimension(.length).raised(to: 3))
      else {
        throw AssistanceValidationFailure(.dimension, "The stated task requires a volume result.")
      }
    }
    if let basis = policy.profitBasis, policy.task.contains("profit") {
      let used = permitted.filter { facts.identifiers.contains($0.name) }
      let cost = used.first { $0.name == "cost" } ?? (used.count == 1 ? used.first : nil)
      let percent = snapshot.evidence(including: permittedHandles).first { record in
        record.source == "T1"
          && record.value.map {
            if case .percentage = $0 { return true }
            return false
          } == true
      }
      let money = snapshot.evidence(including: permittedHandles).filter { record in
        record.source == "T1"
          && record.value.map {
            if case .money = $0 { return true }
            return false
          } == true
      }
      let costSource = cost?.name ?? (money.count == 1 ? money.first?.text : nil)
      guard let costSource, let percent else {
        throw AssistanceValidationFailure(.relation, "Identify the cost and the profit percentage.")
      }
      let expectedSource =
        basis == "cost"
        ? costSource + " + " + percent.text : costSource + " / (1 - " + percent.text + ")"
      let expectedParsing = snapshot.scope.engine.parse(
        expectedSource, context: context, variables: variables)
      guard let expectedExpression = expectedParsing.expression,
        case .value(let expected) = snapshot.scope.engine.evaluate(
          expectedExpression, context: context,
          variables: snapshot.scope.names, lines: snapshot.scope.outcomes,
          manualRates: snapshot.scope.rates,
          functions: snapshot.scope.functions
        ).result,
        assistanceValuesEqual(result, expected, context: context)
      else {
        throw AssistanceValidationFailure(
          .relation, "The expression does not use the selected profit basis.")
      }
    }
    if policy.nominalMonthly, case .call(let name, _, let arguments, _) = expression, name == "pmt",
      arguments.count == 3
    {
      let rate = AssistanceExpressionFacts(
        arguments[1], source: replacement, engine: snapshot.scope.engine, context: context)
      guard
        rate.literals.contains(where: {
          $0.structuralRule == "division_denominator"
            && assistanceValuesEqual(
              $0.value, .number(.integer(IntegerValue(12))), context: context)
        })
      else {
        throw AssistanceValidationFailure(
          .relation, "The payment rate must use the stated nominal annual-to-monthly rule.")
      }
    }
    if policy.task.contains("tax"), selectedChoices["tax_inclusion"] == "included",
      addsPercentage(expression)
    {
      throw AssistanceValidationFailure(.relation, "The supplied prices already include tax.")
    }
    if policy.excludesShippingTax, taxesShipping(expression) {
      throw AssistanceValidationFailure(
        .relation, "The stated tax rule excludes shipping from the tax base.")
    }
    try AssistanceTaskConstraints.check(
      result: result, snapshot: snapshot, policy: policy,
      symbols: permitted,
      evidence: Array(evidence.values).sorted {
        Int($0.handle.dropFirst())! < Int($1.handle.dropFirst())!
      })
    var changes: [LineID] = []
    for (before, after) in zip(safeBaseline.lines, evaluation.lines)
    where before.id != snapshot.target.id && before.result != after.result {
      if isFailure(after.result) {
        throw AssistanceValidationFailure(
          .downstreamFailure, "The edit introduces a downstream failure.",
          engineResult: after.result)
      }
      changes.append(after.id)
    }
    for table in evaluation.tables {
      guard let current = table.calculation else { continue }
      let before = safeBaseline.tables.first { $0.projection?.id == current.table.id }?.calculation
      for (address, result) in current.outcomes {
        if case .failure = result, before?.outcomes[address] != result {
          throw AssistanceValidationFailure(
            .downstreamFailure, "The edit introduces a table failure.")
        }
      }
    }
    let referenceIDs = facts.references.flatMap {
      snapshot.scope.outcomes.lineNumbers(for: $0) ?? []
    }.compactMap { number -> LineID? in
      snapshot.source.lines.indices.contains(number - 1)
        ? snapshot.source.lines[number - 1].id : nil
    }
    guard
      referenceIDs.allSatisfy({ id in
        permitted.contains { $0.declaration?.id == id && !$0.unreviewed }
      })
    else {
      throw AssistanceValidationFailure(
        .unknownBinding, "A line reference is outside the permitted context.")
    }
    return AssistanceCheckedCandidate(
      candidate: candidate, result: result, evaluation: evaluation,
      choices: policy.requiredChoices(
        snapshot: snapshot, result: result, usedSymbols: facts.identifiers,
        literalValues: facts.literals.map(\.value)),
      interpretation: candidate.summary,
      referencedLineIDs: referenceIDs
        + permitted.filter { facts.identifiers.contains($0.name) }.compactMap { $0.declaration?.id },
      changedResults: changes, sourceBefore: snapshot.source.text, sourceAfter: shadow.text,
      rateUses: line.rateUses,
      requiresAssumptionApproval: !Set(candidate.assumptions.map(\.id)).isSubset(
        of: approvedAssumptions), readsClock: facts.readsClock || line.usesClock,
      patches: [
        TableSourcePatch(
          utf8Range: snapshot.target.range.lowerBound..<snapshot.target.range.upperBound,
          expected: snapshot.target.text, replacement: replacement)
      ])
  }

  private static func isFailure(_ result: CalculationResult?) -> Bool {
    switch result {
    case .syntaxFailure, .evaluationFailure: true
    default: false
    }
  }

  private static func addsPercentage(_ expression: Expression) -> Bool {
    switch expression {
    case .infix(let left, let op, let right, _, _):
      if op == .add, case .percentage = right {
        if case .literal(.integer(let digits, .decimal), _) = left, digits == "1" { return false }
        return true
      }
      return addsPercentage(left) || addsPercentage(right)
    case .percentageOperation(let op, let left, let right, _, _):
      return op == .on || addsPercentage(left) || addsPercentage(right)
    case .grouped(let child, _), .money(let child, _, _), .quantity(let child, _, _),
      .conversion(let child, _, _, _), .currencyConversion(let child, _, _):
      return addsPercentage(child)
    case .call(_, _, let arguments, _): return arguments.contains(where: addsPercentage)
    default: return false
    }
  }

  private static func taxesShipping(_ expression: Expression) -> Bool {
    switch expression {
    case .infix(let left, .add, let right, _, _), .infix(let left, .subtract, let right, _, _),
      .infix(let left, .multiply, let right, _, _):
      if case .percentage = right, left.identifiers.contains("shipping") { return true }
      if case .percentage = left, right.identifiers.contains("shipping") { return true }
      return taxesShipping(left) || taxesShipping(right)
    case .percentageOperation(_, let left, let right, _, _):
      return left.identifiers.contains("shipping") || right.identifiers.contains("shipping")
    case .grouped(let child, _), .money(let child, _, _), .quantity(let child, _, _),
      .conversion(let child, _, _, _), .currencyConversion(let child, _, _):
      return taxesShipping(child)
    default: return false
    }
  }
}
