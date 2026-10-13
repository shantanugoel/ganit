import Foundation

public struct AssistanceChoice: Encodable, Equatable, Sendable {
  public let id: String
  public let question: String
  public let options: [Option]

  public struct Option: Encodable, Equatable, Sendable {
    public let id: String
    public let title: String
  }
}

/// Versioned local checks run even when the model declares no assumptions.
struct AssistanceSemanticPolicy {
  static let version = 1
  let task: String
  let choices: [String: String]

  init(snapshot: AssistanceSnapshot, choices: [String: String]) {
    task = snapshot.taskText.lowercased()
    self.choices = choices
  }

  var needsProfitBasis: Bool {
    task.contains("profit") && !task.contains("markup") && !task.contains("of cost")
      && !task.contains("selling price") && !task.contains("margin")
  }
  var profitBasis: String? {
    guard task.contains("profit") else { return nil }
    if task.contains("markup") || task.contains("of cost") { return "cost" }
    if task.contains("selling price") || task.contains("margin") { return "sale" }
    return choices["profit_basis"]
  }
  var annualMonthly: Bool {
    (task.contains("annual") || task.contains("yearly") || task.contains("per year"))
      && (task.contains("monthly") || task.contains("per month"))
  }
  var nominalMonthly: Bool {
    annualMonthly && (task.contains("nominal") || choices["rate_period"] == "nominal")
  }
  var expectedVolume: Bool {
    task.contains("volume") || task.contains("millilitr") || task.contains("millilit")
      || task.range(of: "\\bml\\b", options: .regularExpression) != nil
  }
  var excludesShippingTax: Bool {
    task.contains("tax")
      && (task.contains("items only") || task.contains("excluding shipping")
        || task.contains("exclude shipping"))
  }

  func requiredChoices(
    snapshot: AssistanceSnapshot, result proposed: EngineValue? = nil,
    usedSymbols: Set<String> = [], literalValues: [EngineValue] = []
  )
    -> [AssistanceChoice]
  {
    var result: [AssistanceChoice] = []
    func add(_ id: String, _ question: String, _ options: [(String, String)]) {
      if choices[id] == nil {
        result.append(
          AssistanceChoice(
            id: id, question: question,
            options: options.map { AssistanceChoice.Option(id: $0.0, title: $0.1) }))
      }
    }
    if needsProfitBasis {
      add(
        "profit_basis", "What is the profit based on?",
        [("cost", "Cost"), ("sale", "Selling price")])
    }
    if annualMonthly && !task.contains("nominal") && !task.contains("effective") {
      add(
        "rate_period", "Which annual rate rule applies?",
        [("nominal", "Nominal annual rate"), ("effective", "Effective annual rate")])
    }
    if task.contains("tax") && !excludesShippingTax && !task.contains("add")
      && !task.contains("including")
      && !task.contains("excluded") && !task.contains("exclusive")
    {
      add(
        "tax_inclusion", "Do the supplied prices include tax?",
        [("included", "Tax is included"), ("excluded", "Add tax")])
    }
    if task.contains("split") && (task.contains("except") || task.contains("excluding")) {
      add(
        "split_exclusions", "Which shares include the excluded amount?",
        [("exclude", "Exclude it before the split"), ("separate", "Calculate it separately")])
    }
    if case .syntaxFailure(let diagnostics) = snapshot.evaluation.lines.first(where: {
      $0.id == snapshot.target.id
    })?.result,
      diagnostics.contains(where: { $0.code == .ambiguousSlashDate })
    {
      add(
        "date_order", "What is the date order?",
        [("day_month", "Day, month, year"), ("month_day", "Month, day, year")])
    }
    let massInput =
      snapshot.inventory.contains { record in
        if case .quantity(let value) = record.value {
          return value.unit.dimension == Dimension(.mass)
        }
        return false
      } || task.range(of: "\\b(g|grams?|kg|kilograms?)\\b", options: .regularExpression) != nil
    let densityDimension = try? Dimension(.mass).divided(by: Dimension(.length).raised(to: 3))
    let densityInput = snapshot.inventory.contains { record in
      guard usedSymbols.contains(record.name) else { return false }
      if case .quantity(let value) = record.value {
        return value.unit.dimension == densityDimension
      }
      return false
    }
    let literalDensity = literalValues.contains { value in
      if case .quantity(let quantity) = value { return quantity.unit.dimension == densityDimension }
      return false
    }
    if expectedVolume && massInput && !densityInput && !literalDensity {
      result.append(
        AssistanceChoice(
          id: "missing_density", question: "What density should this conversion use?", options: []))
    }
    if !expectedVolume, let proposed, case .quantity(let next) = proposed,
      case .value(.quantity(let old)) = snapshot.evaluation.lines.first(where: {
        $0.id == snapshot.target.id
      })?.result,
      old.unit.dimension != next.unit.dimension, choices["expected_dimension"] != "proposed"
    {
      result.append(
        AssistanceChoice(
          id: "expected_dimension", question: "Are these the intended result units?",
          options: [
            .init(id: "proposed", title: next.unit.dimension.canonicalDescription),
            .init(id: "edit_request", title: "Specify the intended unit"),
          ]))
    }
    return result
  }
}

extension AssistanceSnapshot {
  public var taskText: String {
    let noteText = notes.filter { !$0.historical }.map(\.source).joined(separator: "\n")
    guard case .calculation(_, _, let range?, let comment) = LineSyntax(target.text),
      let expression = range.text(in: target.text),
      scope.engine.parse(
        String(expression), context: context,
        variables: scope.names.mapValues { $0?.kind ?? .number }
      ).expression != nil
    else { return noteText + "\n" + target.text }
    // A variable name alone does not state the expected result dimension.
    return noteText + "\n" + (comment?.text(in: target.text).map(String.init) ?? "")
  }
}
