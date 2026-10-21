import Foundation

/// Check a small set of explicit relations with independent native expressions.
/// Other relations remain visible interpretations for user review.
struct AssistanceTaskConstraints {
  static func check(
    result: EngineValue, snapshot: AssistanceSnapshot, policy: AssistanceSemanticPolicy,
    symbols: [AssistanceSymbol], evidence: [AssistanceEvidence]
  ) throws {
    let task = policy.task
    let percent = evidence.first { record in
      record.source == "T1"
        && record.value.map {
          if case .percentage = $0 { return true }
          return false
        } == true
    }
    if task.contains("tip"), let percent {
      let amounts = symbols.filter { record in
        if case .money = record.value { return record.kind == "variable" }
        return false
      }
      let bill =
        amounts.first(where: { $0.name == "bill" }) ?? (amounts.count == 1 ? amounts.first : nil)
      let money = evidence.filter { record in
        record.source == "T1"
          && record.value.map {
            if case .money = $0 { return true }
            return false
          } == true
      }
      let billSource = bill?.name ?? (money.count == 1 ? money.first?.text : nil)
      if let billSource {
        var expected = "(" + billSource + " + " + percent.text + ")"
        if task.contains("split") && (task.contains("equal") || task.contains("ways")) {
          let count = evidence.last { record in
            record.source == "T1"
              && record.value.map {
                if case .number = $0 { return true }
                return false
              } == true
          }
          guard let count, let value = count.value else {
            throw AssistanceValidationFailure(.relation, "Supply the number of equal shares.")
          }
          // Canonical integer words use the bounded local conversion rule.
          guard case .number(let number) = value, !number.isNegative, !number.isZero,
            let rounded = try? number.rounded(fractionDigits: 0), !rounded.isRounded
          else {
            throw AssistanceValidationFailure(
              .relation, "Supply a positive whole number of equal shares.")
          }
          expected += " / " + rounded.value.coefficient.canonicalDigits
        }
        try compare(
          expected, to: result, snapshot: snapshot,
          message: "The expression does not add the stated tip and apply the stated split.")
      }
    }
    if policy.excludesShippingTax && task.contains("add"), let percent,
      symbols.contains(where: { $0.name == "items" }),
      symbols.contains(where: { $0.name == "shipping" })
    {
      try compare(
        "(items + " + percent.text + ") + shipping", to: result, snapshot: snapshot,
        message: "The total must apply the stated tax to items only.")
    }
  }

  private static func compare(
    _ source: String, to result: EngineValue, snapshot: AssistanceSnapshot, message: String
  ) throws {
    let parsing = snapshot.scope.engine.parse(
      source, context: snapshot.context,
      variables: snapshot.scope.names.mapValues { $0?.kind ?? .number })
    guard let expression = parsing.expression,
      case .value(let expected) = snapshot.scope.engine.evaluate(
        expression, context: snapshot.context,
        variables: snapshot.scope.names, lines: snapshot.scope.outcomes,
        manualRates: snapshot.scope.rates,
        functions: snapshot.scope.functions
      ).result,
      assistanceValuesEqual(result, expected, context: snapshot.context)
    else { throw AssistanceValidationFailure(.relation, message) }
  }
}
