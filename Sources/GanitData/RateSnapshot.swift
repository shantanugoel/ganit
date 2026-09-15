import CryptoKit
import Foundation

/// One accepted download of ECB euro reference rates.
///
/// `payload` is the provider's response, kept byte for byte. The metadata is
/// Ganit's record about it; rates keep the provider's decimal strings.
public struct RateSnapshot: Equatable, Sendable {
  public static let providerIdentifier = "ecb"
  public static let sourceURL = URL(
    string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

  public let metadata: RateSnapshotMetadata
  public let payload: Data

  public init(metadata: RateSnapshotMetadata, payload: Data) {
    self.metadata = metadata
    self.payload = payload
  }

  /// Stable identity from the observation date and payload checksum, so the
  /// same publication downloaded twice is one snapshot.
  public var id: String {
    let digest = metadata.payloadChecksum.dropFirst("sha256:".count).prefix(16)
    return "\(metadata.observationDate)-\(digest)"
  }

  /// Whether the payload still matches the checksum recorded when accepted.
  public var isIntact: Bool {
    sha256(payload) == metadata.payloadChecksum
  }
}

public struct RateSnapshotMetadata: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public private(set) var schemaVersion = currentSchemaVersion
  public let provider: String
  public let sourceURL: URL
  /// The ECB publication date, `YYYY-MM-DD`.
  public let observationDate: String
  public let retrievedAt: Date
  /// `sha256:` and the lowercase hex digest of the payload.
  public let payloadChecksum: String
  /// Units of each currency per euro, as published.
  public let rates: [String: String]
}

func sha256(_ data: Data) -> String {
  "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
