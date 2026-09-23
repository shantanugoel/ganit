/// Results of the lines above the line being evaluated, used to resolve
/// `line N`, `previous`, and aggregate references.
///
/// A block ends at a blank line, heading, or divider. Aggregates read the
/// current block and skip lines that contain an aggregate themselves;
/// `subtotal` starts after the previous subtotal line in the block.
struct LineOutcomes: Sendable {
  enum Outcome: Hashable, Sendable {
    case none
    case value(EngineValue)
    /// A failed line, by its one-based number, so a reader can be told which.
    case failure(line: Int)
  }

  private var outcomes: [Outcome] = []
  private var aggregates: [Bool] = []
  private var blockStart = 0
  private var subtotalStart = 0

  mutating func append(
    _ outcome: Outcome,
    references: Set<LineReference> = []
  ) {
    outcomes.append(outcome)
    aggregates.append(
      references.contains {
        if case .aggregate = $0 { return true }
        return false
      }
    )
    if references.contains(.aggregate(.subtotal)) {
      subtotalStart = outcomes.count
    }
  }

  /// The number the next appended line will have.
  var nextLine: Int {
    outcomes.count + 1
  }

  mutating func endBlock() {
    blockStart = outcomes.count
    subtotalStart = outcomes.count
  }

  /// The outcomes a reference reads, or `nil` when it names no line above.
  /// Equal inputs always resolve to equal values.
  func inputs(for reference: LineReference) -> [Outcome]? {
    switch reference {
    case .line(let line):
      guard line >= 1, line <= outcomes.count else {
        return nil
      }
      return [outcomes[line - 1]]
    case .previous:
      return (blockStart..<outcomes.count).last { outcomes[$0] != .none }
        .map { [outcomes[$0]] }
    case .aggregate(let aggregate):
      let start = aggregate == .subtotal ? subtotalStart : blockStart
      return (start..<outcomes.count)
        .filter { !aggregates[$0] && outcomes[$0] != .none }
        .map { outcomes[$0] }
    }
  }

  func value(of reference: LineReference) throws -> EngineValue {
    guard let inputs = inputs(for: reference), inputs.count == 1 else {
      throw EngineError(code: .invalidReference)
    }
    return try Self.required(inputs[0])
  }

  func valuesAndLines(for aggregate: Aggregate) throws -> [(line: Int, value: EngineValue)] {
    let start = aggregate == .subtotal ? subtotalStart : blockStart
    return try (start..<outcomes.count)
      .filter { !aggregates[$0] && outcomes[$0] != .none }
      .map { (line: $0 + 1, value: try Self.required(outcomes[$0])) }
  }

  private static func required(_ outcome: Outcome) throws -> EngineValue {
    switch outcome {
    case .none:
      throw EngineError(code: .invalidReference)
    case .value(let value):
      return value
    case .failure(let line):
      throw EngineError(code: .unavailableReference, context: .failedLine(line))
    }
  }
}
