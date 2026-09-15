import Foundation
import GanitData
import Testing

@testable import GanitDocuments

@Suite
struct RateSnapshotStoreTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitRateStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func commitsImmutableSnapshotsAndReloadsLastKnownGood() throws {
    let store = try RateSnapshotStore(root: root)
    #expect(try store.lastKnownGood() == nil)

    let first = try snapshot(date: "2026-09-11")
    #expect(try store.commit(first))
    #expect(try store.commit(first) == false)
    #expect(try RateSnapshotStore(root: root).lastKnownGood() == first)

    let second = try snapshot(date: "2026-09-14", usd: "1.1600")
    try store.commit(second)
    #expect(try store.lastKnownGood() == second)
    #expect(try store.load(id: first.id) == first)
    let payload = root.appending(path: "Snapshots/\(second.id)/payload.xml")
    #expect(try Data(contentsOf: payload) == second.payload)
  }

  @Test
  func rejectedSnapshotsNeverReplaceLastKnownGood() throws {
    let store = try RateSnapshotStore(root: root)
    let good = try snapshot(date: "2026-09-14")
    try store.commit(good)

    #expect(throws: RateSnapshotStoreError.regressingObservationDate) {
      try store.commit(try snapshot(date: "2026-09-11"))
    }
    #expect(throws: RateSnapshotStoreError.regressingObservationDate) {
      try store.commit(try snapshot(date: "2026-09-14", usd: "1.1600"))
    }
    #expect(throws: RateSnapshotStoreError.anomalousRate(currency: "USD")) {
      try store.commit(try snapshot(date: "2026-09-15", usd: "2.5000"))
    }
    let tampered = try snapshot(date: "2026-09-15")
    #expect(throws: RateSnapshotStoreError.corruptSnapshot(tampered.id)) {
      try store.commit(RateSnapshot(metadata: tampered.metadata, payload: Data("x".utf8)))
    }
    #expect(try store.lastKnownGood() == good)
    let names = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "Snapshots").path)
    #expect(names == [good.id])
  }

  @Test
  func rollsBackToTheNewestIntactSnapshot() throws {
    let store = try RateSnapshotStore(root: root)
    let older = try snapshot(date: "2026-09-10")
    let previous = try snapshot(date: "2026-09-11")
    let latest = try snapshot(date: "2026-09-14")
    for snapshot in [older, previous, latest] {
      try store.commit(snapshot)
    }
    try Data("<changed/>".utf8).write(
      to: root.appending(path: "Snapshots/\(latest.id)/payload.xml"))

    #expect(try store.lastKnownGood() == previous)
    #expect(try RateSnapshotStore(root: root).lastKnownGood() == previous)

    for snapshot in [older, previous] {
      try FileManager.default.removeItem(at: root.appending(path: "Snapshots/\(snapshot.id)"))
    }
    #expect(throws: RateSnapshotStoreError.corruptSnapshot(previous.id)) {
      try store.lastKnownGood()
    }
  }

  @Test
  func retainsTheNewestEightSnapshots() throws {
    let store = try RateSnapshotStore(root: root)
    let snapshots = try (1...10).map { try snapshot(date: String(format: "2026-09-%02d", $0)) }
    for snapshot in snapshots {
      try store.commit(snapshot)
    }
    let names = try FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "Snapshots").path)
    #expect(Set(names) == Set(snapshots.suffix(8).map(\.id)))
    let size = try FileManager.default.subpathsOfDirectory(atPath: root.path).reduce(0) {
      $0
        + ((try FileManager.default.attributesOfItem(atPath: root.appending(path: $1).path)[.size]
          as? Int) ?? 0)
    }
    #expect(size < 5_000_000)
    #expect(try store.lastKnownGood() == snapshots.last)
  }

  private func snapshot(date: String, usd: String = "1.1551") throws -> RateSnapshot {
    let codes = [
      "USD", "JPY", "GBP", "CHF", "CZK", "DKK", "HUF", "PLN", "RON", "SEK", "ISK", "NOK", "TRY",
      "AUD", "BRL", "CAD", "CNY", "HKD", "ILS", "INR",
    ]
    let cubes = codes.map { "<Cube currency='\($0)' rate='\($0 == "USD" ? usd : "2.5")'/>" }
    let payload = Data(
      """
      <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"><Cube><Cube time='\(date)'>\
      \(cubes.joined())</Cube></Cube></gesmes:Envelope>
      """.utf8)
    let response = HTTPURLResponse(
      url: RateSnapshot.sourceURL, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "text/xml"])!
    return try ECBRateValidator.snapshot(
      from: payload, response: response, retrievedAt: Date(timeIntervalSince1970: 1_789_500_000))
  }
}
