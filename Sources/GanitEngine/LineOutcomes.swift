/// Results of the lines above the line being evaluated, used to resolve
/// `line N`, `previous`, and aggregate references.
///
/// A block ends at a blank line, heading, or divider. Aggregates read the
/// current block and skip lines that contain an aggregate themselves;
/// `subtotal` starts after the previous subtotal line in the block.
struct LineOutcomes: Sendable {
  enum Outcome: Sendable {
    case none
    case value(EngineValue)
    case failure
  }

  private var outcomes: [Outcome] = []
  private var aggregates: [Bool] = []
  private var blockStart = 0
  private var subtotalStart = 0

  mutating func append(_ outcome: Outcome, expression: Expression? = nil) {
    outcomes.append(outcome)
    aggregates.append(expression?.containsAggregate ?? false)
    if expression?.containsSubtotal == true {
      subtotalStart = outcomes.count
    }
  }

  mutating func endBlock() {
    blockStart = outcomes.count
    subtotalStart = outcomes.count
  }

  func value(atLine line: Int) throws -> EngineValue {
    guard line >= 1, line <= outcomes.count else {
      throw EngineError(code: .invalidReference)
    }
    return try required(outcomes[line - 1])
  }

  func previous() throws -> EngineValue {
    guard
      let index = (blockStart..<outcomes.count).last(where: {
        if case .none = outcomes[$0] { return false }
        return true
      })
    else {
      throw EngineError(code: .invalidReference)
    }
    return try required(outcomes[index])
  }

  func values(for aggregate: Aggregate) throws -> [EngineValue] {
    let start = aggregate == .subtotal ? subtotalStart : blockStart
    return try (start..<outcomes.count).compactMap { index in
      if aggregates[index] {
        return nil
      }
      if case .none = outcomes[index] {
        return nil
      }
      return try required(outcomes[index])
    }
  }

  private func required(_ outcome: Outcome) throws -> EngineValue {
    switch outcome {
    case .none:
      throw EngineError(code: .invalidReference)
    case .value(let value):
      return value
    case .failure:
      throw EngineError(code: .unavailableReference)
    }
  }
}
