import Foundation

/// Keeps one text document, such as Quick Ganit's buffer or the definitions
/// sheet, between launches in an atomically replaced UTF-8 file. The text is
/// never indexed, backed up, or searchable.
public struct TextDocumentStore: Sendable {
  public let url: URL

  public init(url: URL) {
    self.url = url
  }

  /// The stored text, or empty when there is none or it is unreadable.
  public func load() -> String {
    (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  /// Stores text; empty text removes the file.
  public func save(_ text: String) throws {
    guard !text.isEmpty else {
      return try clear()
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try AtomicFile.write(Data(text.utf8), to: url)
  }

  public func clear() throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}
