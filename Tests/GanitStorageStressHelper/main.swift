import Foundation
import GanitDocuments

// Saves one sheet in a loop, alternating two large sources, until killed.
// Usage: GanitStorageStressHelper <library-root> <sheet-id>
guard CommandLine.arguments.count == 3,
  let id = UUID(uuidString: CommandLine.arguments[2])
else {
  FileHandle.standardError.write(Data("usage: GanitStorageStressHelper <root> <sheet-id>\n".utf8))
  exit(64)
}

let library = try SheetLibrary(root: URL(fileURLWithPath: CommandLine.arguments[1]))
var metadata = try library.store.load(id: id).metadata
let sources = ["a", "b"].map { String(repeating: "\($0) = 1 + 2\n", count: 100_000) }
print("ready")
fflush(stdout)
var next = 0
while true {
  metadata = try library.save(source: sources[next], metadata: metadata)
  next = 1 - next
}
