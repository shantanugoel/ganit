import Foundation
import GanitData
import GanitEngine
import Testing

@testable import GanitDocuments

@MainActor
@Suite
struct RateRefresherTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitRateRefresherTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func publishesAcceptedRatesAndKeepsThemAfterRejectedDownloads() async throws {
    let store = try RateSnapshotStore(root: root)
    let downloads = Downloads([try snapshot(date: "2026-09-14")])
    var clock = Date(timeIntervalSince1970: 1_789_500_000)
    let refresher = RateRefresher(
      store: store, isAutomatic: false, now: { clock }, download: downloads.next)
    #expect(refresher.rates == .none)
    var published: [CurrencyRates] = []
    refresher.ratesDidChange = { published.append($0) }

    await refresher.refresh()
    #expect(refresher.rates.observationDate == "2026-09-14")
    #expect(published.count == 1)

    // A failed request leaves the last-known-good rates in place.
    await refresher.refresh()
    #expect(refresher.rates.observationDate == "2026-09-14")
    #expect(published.count == 1)

    // Manual refresh waits a minute after the last attempt.
    #expect(!refresher.refreshNow())
    clock.addTimeInterval(60)
    #expect(refresher.refreshNow())

    let reopened = RateRefresher(store: store, isAutomatic: false, download: downloads.next)
    #expect(reopened.rates == refresher.rates)
  }

  private func snapshot(date: String) throws -> RateSnapshot {
    let codes = [
      "USD", "JPY", "GBP", "CHF", "CZK", "DKK", "HUF", "PLN", "RON", "SEK", "ISK", "NOK", "TRY",
      "AUD", "BRL", "CAD", "CNY", "HKD", "ILS", "INR",
    ]
    let payload = Data(
      """
      <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"><Cube><Cube time='\(date)'>\
      \(codes.map { "<Cube currency='\($0)' rate='1.5'/>" }.joined())</Cube></Cube></gesmes:Envelope>
      """.utf8)
    let response = HTTPURLResponse(
      url: RateSnapshot.sourceURL, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "text/xml"])!
    return try ECBRateValidator.snapshot(
      from: payload, response: response, retrievedAt: Date(timeIntervalSince1970: 1_789_500_000))
  }
}

/// Download results in order, then failures.
private actor Downloads {
  private var results: [RateSnapshot]

  init(_ results: [RateSnapshot]) {
    self.results = results
  }

  nonisolated var next: @Sendable () async throws -> RateSnapshot {
    { try await self.take() }
  }

  private func take() throws -> RateSnapshot {
    guard !results.isEmpty else {
      throw URLError(.notConnectedToInternet)
    }
    return results.removeFirst()
  }
}
