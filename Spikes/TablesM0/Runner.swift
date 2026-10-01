import AppKit
import Foundation
import GanitEngine

struct SpikeFailure: Error, CustomStringConvertible {
  let message: String
  var description: String { message }
}
func check(_ condition: Bool, _ message: String) throws {
  if !condition { throw SpikeFailure(message: message) }
}
@main
struct Runner {
  @MainActor
  static func main() {
    do { try run() } catch {
      print("FAIL:", error)
      exit(1)
    }
  }
  @MainActor
  static func run() throws {
    let args = CommandLine.arguments
    _ = NSApplication.shared
    let table = fixtureTable()
    let canonical = try Codec.encode(table)
    let sheet = "assumption = 2\n" + canonical + "\ncost = sum(Items[Qty])\n"
    if args.contains("--show") {
      let proof = try NativeProof(source: sheet)
      NSApp.setActivationPolicy(.regular)
      proof.window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      withExtendedLifetime(proof) { NSApp.run() }
      return
    }
    for newline in ["\n", "\r", "\r\n"] {
      let encoded = try Codec.encode(table, newline: newline)
      let source = "α = 2" + newline + encoded + newline + "after = 3"
      let blocks = Codec.blocks(source)
      try check(
        blocks.count == 1 && blocks[0].table == table, "round trip \(newline.debugDescription)")
      try check((source as NSString).substring(with: blocks[0].range) == encoded, "source map")
      try check(blocks[0].raw == encoded, "untouched-byte preservation")
      if let index = args.firstIndex(of: "--fixtures"), args.indices.contains(index + 1) {
        let name = newline == "\n" ? "lf" : newline == "\r" ? "cr" : "crlf"
        let url = URL(fileURLWithPath: args[index + 1]).appendingPathComponent("\(name).txt")
        try Data(source.utf8).write(to: url)
      }
    }
    for malformed in [
      canonical.replacingOccurrences(of: "@ganit-table 1", with: "@ganit-table 99"),
      "@ganit-table 1\n{invalid}\n@end-ganit-table", "@ganit-table 1\n10 + 20",
    ] {
      let block = Codec.blocks(malformed)[0]
      try check(block.table == nil && block.diagnostic != nil && block.raw == malformed, "recovery")
    }
    var stale = table
    stale.cells[1].input = "=C2"
    try check((try? stale.validate()) == nil, "reject stale binding")
    var duplicate = table
    duplicate.rows.append("r-a")
    try check((try? duplicate.validate()) == nil, "reject duplicate IDs")
    var conflicting = table
    conflicting.bindings.append(table.bindings[0])
    try check((try? conflicting.validate()) == nil, "reject conflicting ledger")
    try check(
      table.bindings[0].owner != table.bindings[1].owner
        && table.bindings[0].fingerprint == table.bindings[1].fingerprint,
      "duplicate source distinct owners")
    var broken = table
    broken.deleteRow("r-b")
    let reload = Codec.blocks(try Codec.encode(broken))[0].table!
    try check(
      reload.bindings[0].deleted && reload.bindings[0].target.row == "r-b", "broken binding reload")
    broken.rows.append("r-new")
    try check(broken.bindings[0].deleted, "coordinate reuse never repairs deletion")
    print(
      "PASS codec: Unicode, all line endings, quotes/brackets, multiline inputs, decimal comma, |, malformed/unknown, stale/duplicate/conflicting bindings, deletion/reload"
    )
    try verifyGrammar()
    print(
      "PASS reference primitives: address locks, escaped headers/names, legacy token collisions, copy bounds, range insertion/deletion endpoints"
    )
    try verifyProseBindings()
    print(
      "PASS prose: duplicate bound operands -> persisted broken markers -> disk/reload; comments and mixed line endings unchanged"
    )
    let ctx = try context()
    let graph = [
      Node(dependencies: [1, 2], literal: number(0)),
      Node(dependencies: [], literal: number(2)), Node(dependencies: [], literal: number(3)),
      Node(dependencies: [4], literal: number(0)), Node(dependencies: [3], literal: number(0)),
      Node(dependencies: [3], literal: number(1)), Node(dependencies: [], literal: number(7)),
    ]
    let result = try GraphProof.evaluate(graph, context: ctx)
    try check(
      result == [
        .value(number(5)), .value(number(2)), .value(number(3)),
        .cycle([3, 4]), .cycle([3, 4]), .blocked([3, 4]), .value(number(7)),
      ], "SCC outcomes")
    let engine = CalculationEngine()
    guard case .value(let a) = engine.evaluate("0.1", context: ctx),
      case .value(let b) = engine.evaluate("0.2", context: ctx),
      case .value(let exact) = engine.evaluate("0.3", context: ctx)
    else {
      throw SpikeFailure(message: "Ganit literal evaluation")
    }
    let exactGraph = try GraphProof.evaluate(
      [
        Node(dependencies: [1], literal: a),
        Node(dependencies: [], literal: b),
      ], context: ctx)
    try check(exactGraph[0] == .value(exact), "exact decimal graph")
    print(
      "PASS graph trace: A2 -> [B2,A3] = 5; cycle [B3,C3]; A4 blocked by [B3,C3]; D4 = 7; 0.1 + 0.2 = exact 0.3"
    )
    var times: [Double] = []
    let chain = (0..<10_000).map {
      Node(dependencies: $0 == 9_999 ? [] : [$0 + 1], literal: number(1))
    }
    for _ in 0..<21 {
      let start = ContinuousClock.now
      let results = try GraphProof.evaluate(chain, context: ctx)
      let elapsed = start.duration(to: .now).components
      times.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
      try check(results[0] == .value(number(10_000)), "10,000 chain")
    }
    times.sort()
    print(
      String(
        format:
          "MEASURE chain: 10000 cells / 9999 links; 21 samples; median %.3f ms; P95 %.3f ms; max %.3f ms",
        times[10], times[19], times[20]))
    var large = Table(
      id: "t", name: "Stress", columns: [Column(id: "c", name: "Value", policy: "value")],
      rows: [], cells: [], bindings: [], totals: [:])
    let durableRows = (0..<10_000).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
    for index in 0..<10_000 {
      let row = durableRows[index]
      let key = CellKey(table: "t", row: row, column: "c")
      large.rows.append(row)
      large.cells.append(
        Cell(key: key, input: index == 9_999 ? "1" : "=A\(index + 3)", override: false))
      if index != 9_999 {
        large.bindings.append(
          Binding(
            owner: key, fingerprint: fingerprint(large.cells.last!.input), occurrence: 0,
            target: CellKey(table: "t", row: durableRows[index + 1], column: "c"),
            lockRow: false, lockColumn: false, deleted: false))
      }
    }
    let largeBytes = try Codec.encode(large).utf8.count
    let inputBytes = large.cells.reduce(0) { $0 + $1.input.utf8.count + 1 }
    print(
      "MEASURE source: fixture \(canonical.utf8.count) bytes; 10000 chain \(largeBytes) bytes; inputs \(inputBytes) bytes; 1 MB budget exceeded = \(largeBytes > 1_048_576)"
    )
    if let index = args.firstIndex(of: "--fixtures"), args.indices.contains(index + 1) {
      let directory = URL(fileURLWithPath: args[index + 1])
      try Data(Codec.encode(broken).utf8).write(
        to: directory.appendingPathComponent("deleted-target.txt"))
      try CompactTable.encode(table).write(to: directory.appendingPathComponent("compact.json"))
      try Data("@ganit-table 99\n10 + 20\n@end-ganit-table".utf8)
        .write(to: directory.appendingPathComponent("unknown-version.txt"))
      try Data("@ganit-table 1\n{invalid}\n@end-ganit-table".utf8)
        .write(to: directory.appendingPathComponent("malformed.txt"))
    }
    let compact = try CompactTable.encode(large)
    let compactReload = try JSONDecoder().decode(CompactTable.self, from: compact).expanded()
    try check(compactReload == large, "compact identity dictionary round trip")
    let fixtureCompact = try CompactTable.encode(table)
    try check(
      try JSONDecoder().decode(CompactTable.self, from: fixtureCompact).expanded() == table,
      "compact Unicode and binding round trip")
    let brokenCompact = try CompactTable.encode(broken)
    try check(
      try JSONDecoder().decode(CompactTable.self, from: brokenCompact).expanded() == broken,
      "compact deleted target retained outside row dictionary")
    print(
      "MEASURE revised compact source: 10000 chain \(compact.count) bytes; fixture \(fixtureCompact.count) bytes; within 1 MB = \(compact.count < 1_048_576)"
    )
    var bounded = large
    bounded.rows = Array(large.rows.suffix(4_000))
    bounded.cells = Array(large.cells.suffix(4_000))
    bounded.bindings = Array(large.bindings.suffix(3_999))
    let boundedBytes = try CompactTable.encode(bounded).count
    try check(boundedBytes < 1_048_576, "revised 4000-cell source ceiling")
    print("MEASURE revised 4000-cell populated ceiling with UUID row IDs: \(boundedBytes) bytes")
    let sharedRange =
      (0..<1_000).map { _ in Node(dependencies: [], literal: number(1)) }
      + [Node(dependencies: Array(0..<1_000), literal: number(0))]
      + (0..<9_000).map { _ in Node(dependencies: [1_000], literal: number(0)) }
    let rangeStart = ContinuousClock.now
    let rangeResults = try GraphProof.evaluate(sharedRange, context: ctx)
    try check(rangeResults.last == .value(number(1_000)), "shared range node")
    print(
      "MEASURE shared range: 1000 members, 9000 readers, 10000 links, \(rangeStart.duration(to: .now))"
    )
    let dense = (0..<4_000).map { index in
      Node(dependencies: index < 25 ? [] : Array(0..<25), literal: number(index < 25 ? 1 : 0))
    }
    let denseStart = ContinuousClock.now
    let denseResults = try GraphProof.evaluate(dense, context: ctx)
    try check(denseResults.last == .value(number(25)), "dense dependencies")
    print("MEASURE dense: 4000 cells, 99375 links, \(denseStart.duration(to: .now))")
    if args.contains("--native") {
      let snapshotIndex = args.firstIndex(of: "--snapshot")
      let snapshot = snapshotIndex.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
      try NativeProof(source: sheet).verify(snapshot: snapshot)
      print(
        "PASS native: expanded edit -> existing sheet source/Undo/autosave callback; delete -> broken -> disk/reload -> Undo; copy across block; mapped Find selection; Return focus; marked-text simulation; accessibility label"
      )
    }
  }
}
