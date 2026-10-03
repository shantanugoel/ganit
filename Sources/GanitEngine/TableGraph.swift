import Foundation

/// Nodes point to what they read. A bounded range has one membership node,
/// shared by all readers, rather than repeating member edges at each reader.
enum TableDependencyNode: Hashable, Sendable {
  case cell(TableCellAddress)
  case range(TableRangeOperand)
}

struct TableDependencyGraph: Sendable {
  let nodes: [TableDependencyNode]
  let dependencies: [[Int]]
  let reverseDependencies: [[Int]]

  init(nodes: [TableDependencyNode], dependencies: [Set<Int>]) {
    self.nodes = nodes
    self.dependencies = dependencies.map { $0.sorted() }
    var reverse = [[Int]](repeating: [], count: nodes.count)
    for (reader, inputs) in self.dependencies.enumerated() {
      for input in inputs { reverse[input].append(reader) }
    }
    reverseDependencies = reverse
  }

  struct Components {
    /// Dependencies precede readers outside strongly connected components.
    let finishOrder: [Int]
    let components: [[Int]]
  }

  /// Both Kosaraju passes are iterative; a 10,000-cell forward chain never
  /// consumes recursive Swift stack frames.
  func components(cancelled: () -> Bool) throws -> Components {
    var seen = [Bool](repeating: false, count: nodes.count)
    var finish: [Int] = []
    for root in nodes.indices where !seen[root] {
      var stack: [(node: Int, next: Int)] = [(root, 0)]
      seen[root] = true
      while !stack.isEmpty {
        try checkCancellation(cancelled)
        let current = stack.count - 1
        let node = stack[current].node
        let next = stack[current].next
        if next == dependencies[node].count {
          finish.append(node)
          stack.removeLast()
        } else {
          stack[current].next += 1
          let input = dependencies[node][next]
          if !seen[input] {
            seen[input] = true
            stack.append((input, 0))
          }
        }
      }
    }
    seen = [Bool](repeating: false, count: nodes.count)
    var components: [[Int]] = []
    for root in finish.reversed() where !seen[root] {
      var members: [Int] = []
      var stack = [root]
      seen[root] = true
      while let node = stack.popLast() {
        try checkCancellation(cancelled)
        members.append(node)
        for reader in reverseDependencies[node] where !seen[reader] {
          seen[reader] = true
          stack.append(reader)
        }
      }
      components.append(members.sorted())
    }
    return Components(finishOrder: finish, components: components)
  }

  func isCycle(_ component: [Int]) -> Bool {
    component.count > 1 || component.first.map { dependencies[$0].contains($0) } == true
  }

  /// Produces a real closed directed walk, not an address-sorted list. Range
  /// membership nodes remain in the witness so every adjacent pair is an edge.
  func cyclePath(in component: [Int], cancelled: () -> Bool) throws -> [TableDependencyNode] {
    let allowed = Set(component)
    var state: [Int: UInt8] = [:]
    var parents: [Int: Int] = [:]
    for root in component where state[root, default: 0] == 0 {
      var stack: [(node: Int, next: Int)] = [(root, 0)]
      state[root] = 1
      while !stack.isEmpty {
        try checkCancellation(cancelled)
        let current = stack.count - 1
        let node = stack[current].node
        let next = stack[current].next
        if next == dependencies[node].count {
          state[node] = 2
          stack.removeLast()
          continue
        }
        stack[current].next += 1
        let input = dependencies[node][next]
        guard allowed.contains(input) else { continue }
        if state[input] == 1 {
          var path = [node]
          var predecessor = node
          while predecessor != input {
            try checkCancellation(cancelled)
            guard let parent = parents[predecessor] else { return [] }
            path.append(parent)
            predecessor = parent
          }
          return (path.reversed() + [input]).map { nodes[$0] }
        }
        if state[input, default: 0] == 0 {
          parents[input] = node
          state[input] = 1
          stack.append((input, 0))
        }
      }
    }
    return []
  }
}

func checkCancellation(_ cancelled: () -> Bool) throws {
  if cancelled() { throw CancellationError() }
}
