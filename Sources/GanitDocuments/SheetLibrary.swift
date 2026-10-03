import Darwin
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
/// <root>/Sheets/  Metadata/  Folders.json  Index/index.sqlite  Backups/YYYY-MM-DD/{Sheets,Metadata}/
/// ```
///
/// Each backup day mirrors the library layout, so it reads like a store.
///
/// Every change marks the index unsynchronized until the index is updated.
/// Opening a library whose index is missing, corrupt, or unsynchronized
/// recovers sheet metadata from the canonical source files and rebuilds the
/// index.
public final class SheetLibrary {
  /// Called after any sheet is saved, organized, imported, or deleted.
  public var sheetsDidChange: (() -> Void)?
  /// `~/Library/Application Support/<bundle id>`, holding the library, the
  /// quick buffer, and exchange-rate snapshots.
  public static func applicationSupportRoot() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appending(
      path: Bundle.main.bundleIdentifier ?? "com.shantanugoel.Ganit",
      directoryHint: .isDirectory
    )
  }

  public let store: SheetStore
  public let index: SheetIndex
  /// Sheets the last index rebuild could not read, such as ones with an
  /// unsupported metadata schema, or whose metadata could not be recreated.
  /// Their source files were left untouched.
  public private(set) var unreadableSheetIDs: [UUID] = []
  /// Sheets whose metadata repair failed, such as when `Metadata/` cannot be
  /// written, in the last recovery or in `load(id:)` since. After a full
  /// recovery, a sheet whose missing or undecodable metadata could not be
  /// recreated is also in `unreadableSheetIDs`; one that failed on demand is
  /// not added there. A sheet whose stale checksum could not be rewritten
  /// still opens. The library stays marked unsynchronized, so the next open
  /// retries every repair.
  public private(set) var unrepairedSheetIDs: [UUID] = []
  private let backupPolicy: BackupPolicy
  let now: () -> Date
  private let dayFormatter: DateFormatter
  private let folderStore: SheetFolderStore

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
    folderStore = SheetFolderStore(url: root.appending(path: "Folders.json"))
    self.backupPolicy = backupPolicy
    self.now = now
    dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.calendar = Calendar(identifier: .gregorian)
    dayFormatter.timeZone = timeZone
    dayFormatter.dateFormat = "yyyy-MM-dd"
    if index.needsRebuild || FileManager.default.fileExists(atPath: unsyncedMarker.path) {
      try recoverAndRebuildIndex()
    }
  }

  private var unsyncedMarker: URL {
    store.root.appending(path: "Index/unsynchronized")
  }

  /// Whether a change failed after marking the index unsynchronized, since
  /// the last recovery. Its files may be stale, so the marker stays.
  private var hasFailedChange = false

  /// Marks the index unsynchronized while `change` writes sheet files, so an
  /// interruption before the index update is detected on the next open.
  ///
  /// The marker's directory is synchronized before any sheet file changes,
  /// so the marker is durable before they are. A change that fails leaves
  /// the marker until recovery runs, even when later changes succeed.
  private func changingIndexedFiles<Result>(_ change: () throws -> Result) throws -> Result {
    try markUnsynchronized()
    let result: Result
    do {
      result = try change()
    } catch {
      hasFailedChange = true
      throw error
    }
    if !hasFailedChange {
      try FileManager.default.removeItem(at: unsyncedMarker)
    }
    sheetsDidChange?()
    return result
  }

  /// Creates the unsynchronized marker, durably, before files change.
  private func markUnsynchronized() throws {
    // Created in place: an atomic write would leave its own temporary file
    // if interrupted.
    let marker = open(unsyncedMarker.path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o644)
    guard marker >= 0 else {
      throw DocumentStorageError.posix(operation: "open", code: errno)
    }
    close(marker)
    try AtomicFile.synchronizeDirectory(unsyncedMarker.deletingLastPathComponent())
  }

  /// Repairs sheets whose metadata is stale, unreadable, or missing, keeping
  /// their source, and rebuilds the index. Only metadata is written: stale
  /// metadata gets the source's checksum, and a title following the first
  /// line is updated, while unreadable metadata is moved to `Quarantine/`
  /// rather than deleted and recreated from the source. Sheets that still
  /// cannot be read, such as source that is not UTF-8 or metadata in a schema
  /// other than the current one, are left untouched. Temporary files
  /// abandoned by interrupted writes are removed where possible.
  ///
  /// A sheet whose repair fails, such as when `Metadata/` or `Quarantine/`
  /// cannot be written, never keeps the library from opening: it is listed in
  /// `unrepairedSheetIDs`, and in `unreadableSheetIDs` when it cannot be read,
  /// and the library stays marked unsynchronized so the next open retries.
  /// Recovery throws only when the library itself is unusable: the index's
  /// marker cannot be created, `Sheets/` cannot be listed, or the index
  /// cannot be rebuilt.
  ///
  /// The library is marked unsynchronized until the index is rebuilt, so an
  /// interrupted recovery, even one started by a corrupt index, runs again on
  /// the next open.
  ///
  /// The library must be the only writer of its files, with no write in
  /// progress, since recovery rewrites metadata and removes temporary files.
  @discardableResult
  public func recoverAndRebuildIndex() throws -> IndexRebuildReport {
    try markUnsynchronized()
    store.removeTemporaryFiles()
    var unrepaired: [UUID] = []
    for id in try store.sheetIDs() {
      do {
        switch read(id) {
        case .readable(let sheet) where !sheet.isChecksumValid:
          try repairChecksum(of: sheet)
        case .readable, .unreadable:
          continue
        case .recoverable:
          try recoverMetadata(of: id)
        }
      } catch {
        unrepaired.append(id)
      }
    }
    let report = try index.rebuild(from: store)
    unreadableSheetIDs = report.unreadable
    unrepairedSheetIDs = unrepaired
    hasFailedChange = !unrepaired.isEmpty
    if !hasFailedChange {
      try? FileManager.default.removeItem(at: unsyncedMarker)
    }
    return report
  }

  /// Reads a sheet for use, as opening it does, first repairing its metadata
  /// from the canonical source as `recoverAndRebuildIndex()` would: stale
  /// metadata gets the source's checksum, and a title following the first
  /// line, keeping every other field; missing or undecodable metadata is
  /// moved to `Quarantine/` and recreated with reset fields. Only metadata
  /// and the sheet's index entry are written, marked unsynchronized
  /// throughout. A sheet that still cannot be read, such as one with no
  /// source file, source that is not UTF-8, or metadata in another schema,
  /// throws and is left untouched.
  ///
  /// A failed repair leaves the library marked unsynchronized, so the next
  /// open retries it. A sheet whose stale checksum cannot be rewritten is
  /// returned unrepaired, since its metadata is still readable; one whose
  /// metadata cannot be recreated throws.
  public func load(id: UUID) throws -> StoredSheet {
    switch read(id) {
    case .readable(let sheet) where sheet.isChecksumValid:
      return sheet
    case .readable(let sheet):
      do {
        var repaired = try changingIndexedFiles {
          try repairChecksum(of: sheet)
        }
        repaired.metadataRepair = .checksum
        unrepairedSheetIDs.removeAll { $0 == id }
        return repaired
      } catch {
        if !unrepairedSheetIDs.contains(id) {
          unrepairedSheetIDs.append(id)
        }
        return sheet
      }
    case .recoverable:
      do {
        var sheet = try changingIndexedFiles {
          try recoverMetadata(of: id)
        }
        sheet.metadataRepair = .rebuiltFromSource
        unrepairedSheetIDs.removeAll { $0 == id }
        return sheet
      } catch {
        if !unrepairedSheetIDs.contains(id) {
          unrepairedSheetIDs.append(id)
        }
        throw error
      }
    case .unreadable(let error):
      throw error
    }
  }

  private enum Readability {
    case readable(StoredSheet)
    /// Current-schema metadata is missing or cannot be decoded, and the
    /// source file exists.
    case recoverable
    case unreadable(any Error)
  }

  private func read(_ id: UUID) -> Readability {
    do {
      return .readable(try store.load(id: id))
    } catch {
      let isMissing = (error as? CocoaError)?.code == .fileReadNoSuchFile
      guard error is DecodingError || isMissing,
        FileManager.default.fileExists(atPath: store.sourceURL(id).path)
      else {
        return .unreadable(error)
      }
      return .recoverable
    }
  }

  /// Rewrites stale metadata for the current source: its checksum, and its
  /// title when that follows the first line. Returns the sheet as reread,
  /// with its index entry updated, so the source returned is the one the
  /// checksum describes.
  @discardableResult
  private func repairChecksum(of sheet: StoredSheet) throws -> StoredSheet {
    var metadata = sheet.metadata
    if !metadata.hasCustomTitle {
      metadata.title = derivedTitle(of: sheet.source)
    }
    try store.saveMetadata(metadata)
    let repaired = try store.load(id: metadata.id)
    try index.upsert(repaired.metadata, source: repaired.source)
    return repaired
  }

  /// Moves a sheet's metadata, if any, to `Quarantine/` and writes new
  /// metadata for its source, titled after its first line, or "Scratch" for
  /// the scratch sheet. The source file is read, never written. Returns the
  /// sheet as reread, with its index entry updated.
  @discardableResult
  private func recoverMetadata(of id: UUID) throws -> StoredSheet {
    guard let source = exactUTF8(try Data(contentsOf: store.sourceURL(id))) else {
      throw DocumentStorageError.invalidUTF8(store.sourceURL(id))
    }
    let metadataURL = store.metadataURL(id)
    if FileManager.default.fileExists(atPath: metadataURL.path) {
      let quarantine = store.root.appending(path: "Quarantine", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
      try FileManager.default.moveItem(
        at: metadataURL,
        to: quarantine.appending(path: "\(id.uuidString)-\(UUID().uuidString).json")
      )
    }
    var metadata = SheetMetadata(id: id, title: "", createdAt: now(), preferences: .standard)
    if id == Self.scratchID {
      metadata.title = "Scratch"
      metadata.hasCustomTitle = true
    } else {
      metadata.title = derivedTitle(of: source)
    }
    try store.saveMetadata(metadata)
    let recovered = try store.load(id: id)
    try index.upsert(recovered.metadata, source: recovered.source)
    return recovered
  }

  /// The longest title taken from a sheet's first line, in characters and in
  /// UTF-8 bytes, so a long line cannot make a package manifest larger than
  /// import accepts.
  static let maximumDerivedTitleCharacters = 200
  static let maximumDerivedTitleBytes = 1_024

  /// The title of a sheet not named by the user: its first non-blank line,
  /// without a leading U+FEFF or a heading's `#`, cut at a character
  /// boundary to at most 200 characters and 1,024 UTF-8 bytes, without
  /// trailing spaces. A table block counts as its table's name; a block
  /// without a readable table is skipped, so no title is block syntax.
  private func derivedTitle(of source: String) -> String {
    let line =
      TableSourceDocument.displayLines(of: SheetSource(source)).lazy.compactMap { line in
        switch line {
        case .prose(let text): return self.title(of: text)
        case .table(let name, _): return name
        case .quarantined: return nil
        }
      }.first ?? ""
    var title = ""
    var bytes = 0
    for character in line.prefix(Self.maximumDerivedTitleCharacters) {
      bytes += character.utf8.count
      guard bytes <= Self.maximumDerivedTitleBytes else {
        break
      }
      title.append(character)
    }
    return title.trimmingCharacters(in: .whitespaces)
  }

  /// The sheet every library has: somewhere to work a number out without
  /// naming or filing it first. It is created when the library opens, and,
  /// being the one sheet always there, it cannot be deleted.
  public static let scratchID = UUID(uuidString: "5C4A7C40-0000-4000-8000-000000000001")!

  /// Creates the scratch sheet when the library has none, and returns it.
  /// An existing one is read with `load(id:)`, so missing or corrupt
  /// current-schema metadata is recovered from the source, titled
  /// "Scratch". A scratch sheet that still cannot be read, such as one with
  /// an unsupported schema, source that is not UTF-8, or metadata that cannot
  /// be recreated, throws and its source is left untouched.
  @discardableResult
  public func openScratch() throws -> SheetMetadata {
    if FileManager.default.fileExists(atPath: store.sourceURL(Self.scratchID).path) {
      return try load(id: Self.scratchID).metadata
    }
    var metadata = SheetMetadata(
      id: Self.scratchID, title: "Scratch", createdAt: now(), preferences: .standard)
    metadata.hasCustomTitle = true
    return try save(source: "", metadata: metadata)
  }

  /// Creates and saves an empty sheet.
  public func create(preferences: SheetPreferences) throws -> SheetMetadata {
    try save(
      source: "",
      metadata: SheetMetadata(title: "", createdAt: now(), preferences: preferences)
    )
  }

  /// Saves a sheet's source, first backing up the files it replaces if they
  /// have no backup for today. Unless the sheet was renamed, the title
  /// follows the first non-blank line, without a heading's `#`.
  @discardableResult
  public func save(source: String, metadata: SheetMetadata) throws -> SheetMetadata {
    try backUpBeforeFirstChangeToday(metadata.id)
    var metadata = metadata
    metadata.modifiedAt = now()
    if !metadata.hasCustomTitle {
      metadata.title = derivedTitle(of: source)
    }
    return try changingIndexedFiles {
      let saved = try store.save(source: source, metadata: metadata)
      try index.upsert(saved, source: source)
      return saved
    }
  }

  // MARK: Organizing sheets

  /// Changes a sheet's title, favorite flag, folder, or state without
  /// changing its source or modification time.
  @discardableResult
  public func update(
    _ id: UUID,
    _ change: (inout SheetMetadata) -> Void
  ) throws -> SheetMetadata {
    let sheet = try load(id: id)
    var metadata = sheet.metadata
    change(&metadata)
    return try changingIndexedFiles {
      let saved = try store.saveMetadata(metadata)
      try index.upsert(saved, source: sheet.source)
      return saved
    }
  }

  /// Names a sheet; an empty name returns the title to following its first
  /// line.
  @discardableResult
  public func rename(_ id: UUID, to title: String) throws -> SheetMetadata {
    let sheet = try load(id: id)
    var metadata = sheet.metadata
    metadata.hasCustomTitle = !title.isEmpty
    metadata.title = title
    return try save(source: sheet.source, metadata: metadata)
  }

  /// Copies a sheet into a new active sheet in the same folder.
  public func duplicate(_ id: UUID) throws -> SheetMetadata {
    let sheet = try load(id: id)
    var copy = SheetMetadata(
      title: sheet.metadata.title,
      folderID: sheet.metadata.folderID,
      createdAt: now(),
      preferences: sheet.metadata.preferences
    )
    copy.hasCustomTitle = sheet.metadata.hasCustomTitle
    let edit = try TableSourceDocument(sheet.source).duplicateSheet()
    let source = try edit.applying(to: sheet.source)
    // Widths follow the reminted tables and columns. Quarantined blocks
    // remain byte for byte and retain their presentation identities.
    for (table, presentation) in sheet.metadata.tables.byTableID {
      let copiedTable =
        UUID(uuidString: table).flatMap { edit.copiedIdentities[$0] }
        .map { $0.uuidString.lowercased() } ?? table
      for (column, width) in presentation.columnWidths {
        let copiedColumn =
          UUID(uuidString: column).flatMap { edit.copiedIdentities[$0] }
          .map { $0.uuidString.lowercased() } ?? column
        copy.tables.setWidth(width, column: copiedColumn, table: copiedTable)
      }
    }
    return try save(source: source, metadata: copy)
  }

  /// Deletes a sheet's files, index entry, and backups. This cannot be undone,
  /// and the scratch sheet refuses it.
  public func deletePermanently(_ id: UUID) throws {
    guard id != Self.scratchID else {
      throw DocumentStorageError.undeletableSheet(id)
    }
    try changingIndexedFiles {
      try store.delete(id: id)
      try index.remove(id: id)
    }
    for day in try backupDays() {
      try backupStore(day: day).delete(id: id)
    }
  }

  /// Permanently deletes every trashed sheet.
  public func emptyTrash() throws {
    for summary in try index.summaries() where summary.state == .trashed {
      try deletePermanently(summary.id)
    }
  }

  // MARK: Folders

  public func folders() throws -> [SheetFolder] {
    try folderStore.load()
  }

  public func createFolder(named name: String) throws -> SheetFolder {
    let folder = SheetFolder(id: UUID(), name: name)
    try folderStore.save(folders() + [folder])
    return folder
  }

  public func renameFolder(_ id: UUID, to name: String) throws {
    try folderStore.save(folders().map { $0.id == id ? SheetFolder(id: id, name: name) : $0 })
  }

  /// Removes a folder; its sheets move out of it rather than being deleted.
  public func deleteFolder(_ id: UUID) throws {
    for summary in try index.summaries() where summary.folderID == id {
      try update(summary.id) { $0.folderID = nil }
    }
    try folderStore.save(folders().filter { $0.id != id })
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

  private func title(of text: String) -> String? {
    // A leading U+FEFF is invisible; it hides neither a heading nor a blank.
    let line =
      text.unicodeScalars.first == "\u{FEFF}"
      ? String(text.unicodeScalars.dropFirst()) : text
    let text: Substring?
    switch LineSyntax(line) {
    case .blank:
      return nil
    case .heading(let title):
      text = title.text(in: line)
    default:
      text = Substring(line.trimmingCharacters(in: .whitespaces))
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
