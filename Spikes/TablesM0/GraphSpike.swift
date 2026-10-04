import Foundation
import GanitEngine

struct Node {
  var dependencies: [Int]
  var literal: EngineValue
}
enum Outcome: Equatable {
  case value(EngineValue)
  case cycle([Int])
  case blocked([Int])
}
struct GraphProof {
  // Kosaraju, both passes iterative. Shared range nodes will use the same graph.
  static func evaluate(_ nodes: [Node], context: EvaluationContext) throws -> [Outcome] {
    let count = nodes.count
    var reverse = Array(repeating: [Int](), count: count)
    for (index, node) in nodes.enumerated() {
      for dep in node.dependencies {
        try check(nodes.indices.contains(dep), "out of bounds dependency")
        reverse[dep].append(index)
      }
    }
    var visited = Array(repeating: false, count: count)
    var finished: [Int] = []
    for root in nodes.indices where !visited[root] {
      var stack: [(Int, Int)] = [(root, 0)]
      visited[root] = true
      while let (node, next) = stack.last {
        try Task.checkCancellation()
        if next < nodes[node].dependencies.count {
          stack[stack.count - 1].1 += 1
          let dep = nodes[node].dependencies[next]
          if !visited[dep] {
            visited[dep] = true
            stack.append((dep, 0))
          }
        } else {
          finished.append(node)
          stack.removeLast()
        }
      }
    }
    var components = Array(repeating: -1, count: count)
    var groups: [[Int]] = []
    for root in finished.reversed() where components[root] == -1 {
      let component = groups.count
      var group: [Int] = []
      var stack = [root]
      components[root] = component
      while let node = stack.popLast() {
        group.append(node)
        for next in reverse[node] where components[next] == -1 {
          components[next] = component
          stack.append(next)
        }
      }
      groups.append(group.sorted())
    }
    var results = [Outcome?](repeating: nil, count: count)
    for group in groups where group.count > 1 || nodes[group[0]].dependencies.contains(group[0]) {
      for node in group { results[node] = .cycle(group) }
    }
    let evaluator = Evaluator(context: context)
    // DFS finishing order visits dependencies before their readers, excluding SCCs.
    for node in finished where results[node] == nil {
      var values = [nodes[node].literal]
      var failures: Set<Int> = []
      for dep in nodes[node].dependencies {
        switch results[dep] {
        case .value(let value): values.append(value)
        case .cycle(let causes), .blocked(let causes): failures.formUnion(causes)
        case nil: throw SpikeFailure(message: "incorrect dependency ordering")
        }
      }
      results[node] =
        failures.isEmpty
        ? .value(try evaluator.aggregating(.sum, of: values))
        : .blocked(failures.sorted())
    }
    return results.map { $0! }
  }
}
func context() throws -> EvaluationContext {
  try EvaluationContext(
    localeIdentifier: "en-US", lexingConfiguration: .englishUnitedStates,
    angleMode: .radians, precision: PrecisionContext(significantDecimalDigits: 15),
    now: Date(timeIntervalSince1970: 0), calendar: Calendar(identifier: .gregorian),
    timeZone: TimeZone(secondsFromGMT: 0)!)
}
func number(_ value: Int) -> EngineValue { .number(.integer(IntegerValue(value))) }
