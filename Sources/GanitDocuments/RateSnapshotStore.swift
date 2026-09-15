import Foundation
import GanitData

public enum RateSnapshotStoreError: Error, Equatable, Sendable {
  case corruptSnapshot(String)
  case regressingObservationDate
  case anomalousRate(currency: String)
}

/// Immutable currency snapshots and the last-known-good pointer.
///
/// Each snapshot is a directory named by its ID holding the provider payload,
/// byte for byte, and Ganit's metadata. A snapshot directory is written
/// completely under a temporary name and renamed into place, and is never
/// changed afterwards. `LastKnownGood` names the accepted snapshot and is
/// replaced atomically only after the new snapshot is committed, so a crash
/// or rejected download leaves the previous snapshot in use.
public struct RateSnapshotStore: Sendable {
  public static let retainedSnapshotCount = 8
  /// A rate that more than doubles or halves against the last-known-good
  /// snapshot is treated as an anomaly rather than a market move.
  static let maximumRateRatio = 2.0

  public let root: URL
  private var snapshots: URL { root.appending(path: "Snapshots", directoryHint: .isDirectory) }
  private var pointer: URL { root.appending(path: "LastKnownGood") }

  public init(root: URL) throws {
    self.root = root
    try FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true)
  }

  /// The accepted snapshot, or `nil` before the first one.
  public func lastKnownGood() throws -> RateSnapshot? {
    guard let data = try? Data(contentsOf: pointer) else {
      return nil
    }
    return try load(id: String(decoding: data, as: UTF8.self))
  }

  public func load(id: String) throws -> RateSnapshot {
    let directory = snapshots.appending(path: id, directoryHint: .isDirectory)
    guard let payload = try? Data(contentsOf: directory.appending(path: "payload.xml")),
      let metadataData = try? Data(contentsOf: directory.appending(path: "metadata.json")),
      let metadata = try? Self.decoder.decode(RateSnapshotMetadata.self, from: metadataData),
      metadata.schemaVersion == RateSnapshotMetadata.currentSchemaVersion
    else {
      throw RateSnapshotStoreError.corruptSnapshot(id)
    }
    let snapshot = RateSnapshot(metadata: metadata, payload: payload)
    guard snapshot.isIntact, snapshot.id == id else {
      throw RateSnapshotStoreError.corruptSnapshot(id)
    }
    return snapshot
  }

  /// Commits a validated snapshot as last-known-good. Returns `false` when it
  /// is already the last-known-good snapshot.
  @discardableResult
  public func commit(_ snapshot: RateSnapshot) throws -> Bool {
    guard snapshot.isIntact else {
      throw RateSnapshotStoreError.corruptSnapshot(snapshot.id)
    }
    if let current = try? lastKnownGood() {
      guard current.id != snapshot.id else {
        return false
      }
      guard snapshot.metadata.observationDate > current.metadata.observationDate else {
        throw RateSnapshotStoreError.regressingObservationDate
      }
      for (currency, rate) in snapshot.metadata.rates {
        guard let previous = current.metadata.rates[currency].flatMap(Double.init),
          let next = Double(rate)
        else {
          continue
        }
        guard (1 / Self.maximumRateRatio...Self.maximumRateRatio).contains(next / previous) else {
          throw RateSnapshotStoreError.anomalousRate(currency: currency)
        }
      }
    }
    try write(snapshot)
    try AtomicFile.write(Data(snapshot.id.utf8), to: pointer)
    try prune(keeping: snapshot.id)
    return true
  }

  private func write(_ snapshot: RateSnapshot) throws {
    let destination = snapshots.appending(path: snapshot.id, directoryHint: .isDirectory)
    if (try? load(id: snapshot.id)) != nil {
      return
    }
    try? FileManager.default.removeItem(at: destination)
    let temporary = snapshots.appending(path: ".\(snapshot.id).\(UUID().uuidString).tmp")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    do {
      try AtomicFile.write(snapshot.payload, to: temporary.appending(path: "payload.xml"))
      try AtomicFile.write(
        Self.encoder.encode(snapshot.metadata), to: temporary.appending(path: "metadata.json"))
      try FileManager.default.moveItem(at: temporary, to: destination)
      try AtomicFile.synchronizeDirectory(snapshots)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  /// Removes abandoned temporary directories and all but the newest retained
  /// snapshots, never the last-known-good one.
  private func prune(keeping current: String) throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
    let retained = Set(
      names.filter { !AtomicFile.isTemporary($0) }.sorted(by: >)
        .prefix(Self.retainedSnapshotCount)
    ).union([current])
    for name in names where !retained.contains(name) {
      try? FileManager.default.removeItem(at: snapshots.appending(path: name))
    }
  }

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }()

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}
