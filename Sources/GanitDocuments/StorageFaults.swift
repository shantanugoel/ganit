import Foundation

/// A named point in a durable write, where tests stop the write to prove that
/// storage stays complete. See docs/storage/fault-tolerance.md.
@_spi(StorageFaults)
public enum StorageWritePoint: String, Sendable {
  /// An atomic file write's empty temporary sibling exists. The URL is the
  /// destination file.
  case temporaryCreated
  /// The temporary file holds all the data, not yet flushed.
  case temporaryWritten
  /// The temporary file is flushed and closed, not yet renamed.
  case temporaryFlushed
  /// The temporary file has replaced the destination; its directory is not
  /// yet synchronized.
  case renamed
  /// A directory is about to be synchronized. The URL is the directory.
  case synchronizingDirectory
  /// A package's empty temporary directory exists. The URL is the package.
  case packageDirectoryCreated
  /// A package's temporary directory holds every file, not yet swapped or
  /// renamed into place.
  case packageAssembled
  /// The package has been swapped or renamed into place; its directory is not
  /// yet synchronized.
  case packageReplaced
  /// The package swapped in is synchronized, and the package it replaced is
  /// about to be removed. A package written to a new destination never
  /// reaches this point.
  case removingReplacedPackage
}

/// Test-only fault injection for durable writes.
///
/// Writers report each `StorageWritePoint` they reach. A handler bound with
/// `StorageFaults.$handler.withValue(_:operation:)` sees those reports for
/// the current task only, and can throw to make the write fail there or stop
/// the process to interrupt it. Nothing outside tests binds a handler, so
/// reaching a point only reads an unset task-local value.
@_spi(StorageFaults)
public enum StorageFaults {
  public typealias Handler = @Sendable (StorageWritePoint, URL) throws -> Void

  @TaskLocal public static var handler: Handler?

  static func reach(_ point: StorageWritePoint, _ url: URL) throws {
    try handler?(point, url)
  }
}
