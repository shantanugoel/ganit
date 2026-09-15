import Foundation
import GanitEngine

/// A daily snapshot of a sheet's files taken before they were first replaced
/// that day.
public struct SheetBackup: Equatable, Sendable {
  public let sheetID: UUID
  /// The backup day, as `YYYY-MM-DD` in the library's time zone.
  public let day: String
}

/// How many daily backups a library keeps.
public struct BackupPolicy: Equatable, Sendable {
  public static let `default` = BackupPolicy(maximumDays: 30, maximumBytes: 100 << 20)

  /// The newest backup days to keep.
  public let maximumDays: Int
  /// The total size to keep; older days are removed first, but the newest day
  /// always remains.
  public let maximumBytes: Int

  public init(maximumDays: Int, maximumBytes: Int) {
    precondition(maximumDays > 0 && maximumBytes > 0)
    self.maximumDays = maximumDays
    self.maximumBytes = maximumBytes
  }
}

/// Sheets on disk: canonical files, a derived index, and bounded daily
/// backups under one root.
///
/// ```text
/// <root>/Sheets/  Metadata/  Index/index.sqlite  Backups/YYYY-MM-DD/{Sheets,Metadata}/
/// ```
///
/// Each backup day mirrors the library layout, so it reads like a store.
public final class SheetLibrary {
  public let store: SheetStore
  public let index: SheetIndex
  private let backupPolicy: BackupPolicy
  private let now: () -> Date
  private let dayFormatter: DateFormatter

  private var backupsDirectory: URL {
    store.root.appending(path: "Backups", directoryHint: .isDirectory)
  }

  /// Opens a library, rebuilding its index from sheet files when needed.
  public init(
    root: URL,
    backupPolicy: BackupPolicy = .default,
    timeZone: TimeZone = .current,
    now: @escaping () -> Date = Date.init
  ) throws {
    store = SheetStore(root: root)
    index = try SheetIndex(url: root.appending(path: "Index/index.sqlite"))
    self.backupPolicy = backupPolicy
    self.now = now
    dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.calendar = Calendar(identifier: .gregorian)
    dayFormatter.timeZone = timeZone
    dayFormatter.dateFormat = "yyyy-MM-dd"
    if index.needsRebuild {
      try index.rebuild(from: store)
    }
  }

  /// Creates and saves an empty sheet.
  public func create(preferences: SheetPreferences) throws -> SheetMetadata {
    try save(
      source: "",
      metadata: SheetMetadata(title: "", createdAt: now(), preferences: preferences)
    )
  }

  /// Saves a sheet's source, first backing up the files it replaces if they
  /// have no backup for today. The title follows the first non-blank line,
  /// without a heading's `#`.
  @discardableResult
  public func save(source: String, metadata: SheetMetadata) throws -> SheetMetadata {
    try backUpBeforeFirstChangeToday(metadata.id)
    var metadata = metadata
    metadata.modifiedAt = now()
    metadata.title = SheetSource(source).lines.lazy.compactMap(title(of:)).first ?? ""
    let saved = try store.save(source: source, metadata: metadata)
    try index.upsert(saved, source: source)
    return saved
  }

  /// A sheet's backups, newest first.
  public func backups(of id: UUID) throws -> [SheetBackup] {
    try backupDays().reversed().filter {
      FileManager.default.fileExists(atPath: backupSource(id, day: $0).path)
    }
    .map { SheetBackup(sheetID: id, day: $0) }
  }

  /// The source and metadata a backup captured.
  public func load(_ backup: SheetBackup) throws -> StoredSheet {
    try backupStore(day: backup.day).load(id: backup.sheetID)
  }

  private func backUpBeforeFirstChangeToday(_ id: UUID) throws {
    let day = dayFormatter.string(from: now())
    guard FileManager.default.fileExists(atPath: store.sourceURL(id).path),
      !FileManager.default.fileExists(atPath: backupSource(id, day: day).path)
    else {
      return
    }
    let backup = backupStore(day: day)
    for url in [backup.metadataURL(id), backup.sourceURL(id)] {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    }
    // Metadata is copied first, so a backup with source is always complete.
    try AtomicFile.write(Data(contentsOf: store.metadataURL(id)), to: backup.metadataURL(id))
    try AtomicFile.write(Data(contentsOf: store.sourceURL(id)), to: backup.sourceURL(id))
    try pruneBackups()
  }

  private func pruneBackups() throws {
    var days = try backupDays()
    var sizes = try days.map(directorySize)
    while days.count > 1,
      days.count > backupPolicy.maximumDays || sizes.reduce(0, +) > backupPolicy.maximumBytes
    {
      try FileManager.default.removeItem(at: backupsDirectory.appending(path: days[0]))
      days.removeFirst()
      sizes.removeFirst()
    }
  }

  /// Backup day folder names, oldest first.
  private func backupDays() throws -> [String] {
    guard FileManager.default.fileExists(atPath: backupsDirectory.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)
      .filter { dayFormatter.date(from: $0) != nil }
      .sorted()
  }

  private func title(of line: SheetLine) -> String? {
    let text: Substring?
    switch LineSyntax(line.text) {
    case .blank:
      return nil
    case .heading(let title):
      text = title.text(in: line.text)
    default:
      text = Substring(line.text.trimmingCharacters(in: .whitespaces))
    }
    return text.flatMap { $0.isEmpty ? nil : String($0) }
  }

  private func backupStore(day: String) -> SheetStore {
    SheetStore(root: backupsDirectory.appending(path: day, directoryHint: .isDirectory))
  }

  private func backupSource(_ id: UUID, day: String) -> URL {
    backupStore(day: day).sourceURL(id)
  }

  private func directorySize(_ day: String) throws -> Int {
    let directory = backupsDirectory.appending(path: day)
    guard
      let files = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.fileSizeKey])
    else {
      return 0
    }
    return files.compactMap {
      ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
    }
    .reduce(0, +)
  }
}
