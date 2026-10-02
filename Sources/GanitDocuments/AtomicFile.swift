import Darwin
import Foundation

public enum DocumentStorageError: Error, Equatable {
  case posix(operation: String, code: Int32)
  case invalidUTF8(URL)
  case unsupportedSchemaVersion(Int)
  case undeletableSheet(UUID)
}

/// Replaces a file so readers see either its previous or its new complete
/// contents, never a partial write.
///
/// Data goes to a uniquely named sibling temporary file, is flushed to stable
/// storage with `F_FULLFSYNC`, and is renamed over the destination. The
/// directory is then synchronized so the rename itself survives power loss.
enum AtomicFile {
  static func write(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    // `isWriterTemporary` matches exactly this name, uppercase UUID included.
    let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let descriptor = Int32(
      try check("open") { open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644) }
    )
    do {
      try StorageFaults.reach(.temporaryCreated, url)
      try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let written = try check("write") {
            Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
          }
          offset += written
        }
      }
      try StorageFaults.reach(.temporaryWritten, url)
      try check("fsync") { fcntl(descriptor, F_FULLFSYNC) }
      try check("close") { close(descriptor) }
    } catch {
      close(descriptor)
      unlink(temporary.path)
      throw error
    }
    do {
      try StorageFaults.reach(.temporaryFlushed, url)
      try check("rename") { rename(temporary.path, url.path) }
    } catch {
      unlink(temporary.path)
      throw error
    }
    try StorageFaults.reach(.renamed, url)
    try synchronizeDirectory(directory)
  }

  static func synchronizeDirectory(_ directory: URL) throws {
    try StorageFaults.reach(.synchronizingDirectory, directory)
    let descriptor = Int32(try check("open") { open(directory.path, O_RDONLY | O_CLOEXEC) })
    defer { close(descriptor) }
    try check("fsync") { fsync(descriptor) }
  }

  /// Whether a file name is an in-progress or abandoned temporary write.
  static func isTemporary(_ name: String) -> Bool {
    name.hasPrefix(".") && name.hasSuffix(".tmp")
  }

  /// Whether a name has exactly the shape `write(_:to:)` gives its
  /// temporary files, `.<name>.<UUID>.tmp`, so cleanup never matches a name
  /// a person chose, such as `.tmp` or `.notes.tmp`.
  static func isWriterTemporary(_ name: String) -> Bool {
    guard name.hasPrefix("."), name.hasSuffix(".tmp") else {
      return false
    }
    let stem = name.dropFirst().dropLast(4)
    guard let dot = stem.lastIndex(of: "."), dot > stem.startIndex else {
      return false
    }
    let uuid = stem[stem.index(after: dot)...]
    return UUID(uuidString: String(uuid))?.uuidString == String(uuid)
  }

  @discardableResult
  private static func check<Result: BinaryInteger>(
    _ operation: String,
    _ call: () -> Result
  ) throws -> Int {
    let result = call()
    guard result >= 0 else {
      throw DocumentStorageError.posix(operation: operation, code: errno)
    }
    return Int(result)
  }
}
