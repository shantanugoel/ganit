import os

/// A Points of Interest signpost interval that also measures its duration.
///
/// Interval names are static and no metadata is attached, so signposts never
/// carry sheet text.
public struct SignpostedInterval {
  private static let signposter = OSSignposter(
    subsystem: "com.shantanugoel.Ganit",
    category: .pointsOfInterest
  )

  private let name: StaticString
  private let state: OSSignpostIntervalState
  private let start: ContinuousClock.Instant

  public static func begin(_ name: StaticString) -> SignpostedInterval {
    SignpostedInterval(
      name: name,
      state: signposter.beginInterval(name, id: signposter.makeSignpostID()),
      start: .now
    )
  }

  /// Ends the interval and returns how long it lasted.
  @discardableResult
  public func end() -> Duration {
    Self.signposter.endInterval(name, state)
    return start.duration(to: .now)
  }

  /// Ends an interval whose work was superseded or cancelled.
  public func cancel() {
    Self.signposter.endInterval(name, state, "cancelled")
  }
}
