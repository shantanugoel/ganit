import Foundation
@_spi(StorageFaults) import GanitDocuments
import os

// Interrupts storage writes for StorageFaultTests.
//
//   save-loop <root> <sheet-id> <source-a> <source-b>
//     Saves the sheet in a loop, alternating the two source files, until killed.
//   export-loop <package> <source-a> <source-b>
//     Exports a package in a loop, alternating the two source files, until killed.
//   crash-save <root> <sheet-id> <source> <hit>
//   crash-export <package> <source> <hit>
//     Saves the sheet, or exports the package with Quick Look files, once, and
//     kills itself with SIGKILL on reaching its <hit>th storage write point,
//     counting from 1. If the write finishes first, prints
//     "completed <points reached>".
//
// Loops print "ready" before their first write.
func usage() -> Never {
  FileHandle.standardError.write(
    Data(
      """
      usage: GanitStorageStressHelper save-loop <root> <sheet-id> <source-a> <source-b>
             GanitStorageStressHelper export-loop <package> <source-a> <source-b>
             GanitStorageStressHelper crash-save <root> <sheet-id> <source> <hit>
             GanitStorageStressHelper crash-export <package> <source> <hit>

      """.utf8))
  exit(64)
}

func source(_ path: String) throws -> String {
  try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
}

func sheetID(_ text: String) -> UUID {
  guard let id = UUID(uuidString: text) else { usage() }
  return id
}

func hit(_ text: String) -> Int {
  guard let hit = Int(text), hit > 0 else { usage() }
  return hit
}

func ready() {
  print("ready")
  fflush(stdout)
}

/// Runs `write`, killing the process on reaching storage write point `hit`.
func crashing(atHit hit: Int, _ write: () throws -> Void) throws {
  let reached = OSAllocatedUnfairLock(initialState: 0)
  try StorageFaults.$handler.withValue(
    { _, _ in
      let count = reached.withLock {
        $0 += 1
        return $0
      }
      if count == hit {
        kill(getpid(), SIGKILL)
      }
    },
    operation: write)
  print("completed \(reached.withLock { $0 })")
}

let arguments = Array(CommandLine.arguments.dropFirst())
// Fixed, so every export of the same source writes the same bytes.
let exportMetadata = SheetMetadata(
  id: UUID(uuidString: "6A4E2C10-0000-4000-8000-0000000000F2")!, title: "Stress",
  createdAt: Date(timeIntervalSince1970: 1_789_459_200),
  preferences: .standard)

switch (arguments.first, arguments.count) {
case ("save-loop", 5):
  let library = try SheetLibrary(root: URL(fileURLWithPath: arguments[1]))
  var metadata = try library.store.load(id: sheetID(arguments[2])).metadata
  let sources = try [source(arguments[3]), source(arguments[4])]
  ready()
  var next = 0
  while true {
    metadata = try library.save(source: sources[next], metadata: metadata)
    next = 1 - next
  }
case ("export-loop", 4):
  let package = URL(fileURLWithPath: arguments[1])
  let sources = try [source(arguments[2]), source(arguments[3])]
  ready()
  var next = 0
  while true {
    try SheetExchange.write(
      source: sources[next], metadata: exportMetadata, to: package, quickLook: nil)
    next = 1 - next
  }
case ("crash-save", 5):
  let library = try SheetLibrary(root: URL(fileURLWithPath: arguments[1]))
  let metadata = try library.store.load(id: sheetID(arguments[2])).metadata
  let text = try source(arguments[3])
  try crashing(atHit: hit(arguments[4])) { try library.save(source: text, metadata: metadata) }
case ("crash-export", 4):
  let package = URL(fileURLWithPath: arguments[1])
  let text = try source(arguments[2])
  try crashing(atHit: hit(arguments[3])) {
    try SheetExchange.write(
      source: text, metadata: exportMetadata, to: package,
      quickLook: QuickLookPreview(pdf: Data("pdf".utf8), thumbnailPNG: Data("png".utf8)))
  }
default:
  usage()
}
