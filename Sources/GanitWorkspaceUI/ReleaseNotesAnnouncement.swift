import Foundation

/// Shows the changelog once for each installed release, after any welcome tour.
@MainActor
public final class ReleaseNotesAnnouncement {
  public static let seenVersionKey = "LastSeenReleaseNotesVersion"
  private let defaults: UserDefaults
  private let version: String?

  public init(
    defaults: UserDefaults = .standard,
    version: String? = Bundle.main.object(
      forInfoDictionaryKey: "CFBundleVersion") as? String
  ) {
    self.defaults = defaults
    self.version = version
  }

  public var shouldShow: Bool {
    guard let version, !version.isEmpty else { return false }
    return defaults.string(forKey: Self.seenVersionKey) != version
  }

  /// Mark only after the window is actually presented, so deferred launches
  /// and a failed presentation do not consume the announcement.
  public func didShow() {
    guard let version, !version.isEmpty else { return }
    defaults.set(version, forKey: Self.seenVersionKey)
  }
}
