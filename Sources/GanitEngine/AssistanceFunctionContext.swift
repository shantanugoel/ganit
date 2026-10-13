import Foundation
import GanitSuggestionProtocol

/// A flat native closure record. It contains only the body and its actual captures.
struct AssistanceFunctionContext: Encodable, Sendable {
  struct Capture: Encodable, Sendable {
    let name: String
    let origin: String
    let source: String?
    let value: AssistanceValue?
    let unavailable: Bool
  }
  struct Call: Encodable, Sendable {
    let name: String
    let origin: String
  }
  struct Definition: Encodable, Sendable {
    let name: String
    let origin: String
    let source: String
    let parameters: [String]
    let captures: [Capture]
    let functions: [Call]
    let units: [AssistanceValue]
    let readsClock: Bool
  }
  let definitions: [Definition]
  let origins: [AssistanceDeclarationOrigin]
  private enum CodingKeys: String, CodingKey { case definitions }
  var hasUnavailableCapture: Bool {
    definitions.contains { $0.captures.contains(where: \.unavailable) }
  }
  var recordCount: Int {
    definitions.reduce(0) { $0 + 1 + $1.captures.count + $1.units.count }
  }

  init(_ root: CustomFunction, engine: CalculationEngine, context: EvaluationContext) throws {
    var work = [root]
    var visited: Set<String> = []
    var records: [Definition] = []
    var origins: [AssistanceDeclarationOrigin] = []
    var count = 0
    while let function = work.popLast() {
      guard let origin = function.assistanceOrigin else {
        throw AssistanceValidationFailure(
          .unknownBinding, "The function has no native source record.")
      }
      guard visited.insert(origin.identifier).inserted else { continue }
      origins.append(origin)
      let facts = AssistanceExpressionFacts(
        function.body, source: origin.source, engine: engine, context: context)
      guard !function.hasUnreviewedCapture, !facts.containsAssistant else {
        throw AssistanceValidationFailure(
          .unsupportedOperation, "The function has an unreviewed model dependency.")
      }
      let names = facts.identifiers.subtracting(function.parameters).sorted()
      origins += names.compactMap { function.assistanceCaptures[$0] }
      let captures = names.filter { function.variables.keys.contains($0) }.map { name in
        let source = function.assistanceCaptures[name]
        let value = function.variables[name] ?? nil
        return Capture(
          name: name, origin: source?.identifier ?? "external-definitions:" + name,
          source: source?.source, value: value.map(AssistanceValue.init), unavailable: value == nil)
      }
      var calls: [Call] = []
      for name in facts.calls.sorted() {
        guard let called = function.functions[name] else { continue }
        guard let origin = called.assistanceOrigin else {
          throw AssistanceValidationFailure(
            .unknownBinding, "A captured function has no native source record.")
        }
        calls.append(Call(name: name, origin: origin.identifier))
        work.append(called)
      }
      let units = Self.units(in: function.body, engine: engine, context: context)
      count += 1 + captures.count + units.count
      guard count <= SuggestionLimits.symbols else { throw AssistanceSnapshotError.contextTooLarge }
      records.append(
        Definition(
          name: function.name, origin: origin.identifier, source: origin.source,
          parameters: function.parameters, captures: captures, functions: calls, units: units,
          readsClock: facts.readsClock))
    }
    definitions = records
    self.origins = origins
  }

  /// Evaluate one unit with its compiled syntax, which retains custom-unit transforms.
  private static func units(
    in expression: Expression, engine: CalculationEngine, context: EvaluationContext
  ) -> [AssistanceValue] {
    var work = [expression]
    var values: [EngineValue] = []
    while let node = work.popLast() {
      switch node {
      case .quantity(let child, let unit, let range),
        .conversion(let child, let unit, _, let range):
        let one = Expression.literal(.integer(digits: "1", radix: .decimal), range: range)
        let quantity = Expression.quantity(magnitude: one, unit: unit, range: range)
        if case .value(let value) = engine.evaluate(
          quantity, context: context, variables: [:], lines: LineOutcomes()
        ).result,
          !values.contains(value)
        {
          values.append(value)
        }
        work.append(child)
      case .infix(let a, _, let b, _, _), .percentageOperation(_, let a, let b, _, _):
        work.append(contentsOf: [a, b])
      case .call(_, _, let arguments, _): work.append(contentsOf: arguments)
      case .prefix(_, let child, _, _), .percentage(let child, _, _), .grouped(let child, _),
        .money(let child, _, _), .currencyConversion(let child, _, _),
        .zoneConversion(let child, _, _),
        .period(let child, _, _), .relative(let child, _, _):
        work.append(child)
      default: break
      }
    }
    return values.map(AssistanceValue.init)
  }
}
