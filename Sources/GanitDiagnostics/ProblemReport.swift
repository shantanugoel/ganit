import Foundation

/// A plain-text problem report the user saves and sends themselves.
///
/// It describes the app and system only. A sheet's text appears solely when
/// the user explicitly includes it as a reproduction; nothing is uploaded.
public struct ProblemReport: Equatable, Sendable {
  public var appVersion: String
  public var systemVersion: String
  public var hardwareModel: String
  /// Option names and values, such as whether exchange rates update.
  public var settings: [String: String]
  public var sheetCount: Int
  /// The current sheet's text, when the user chose to include it.
  public var reproduction: String?

  public init(
    appVersion: String, systemVersion: String, hardwareModel: String,
    settings: [String: String], sheetCount: Int, reproduction: String?
  ) {
    self.appVersion = appVersion
    self.systemVersion = systemVersion
    self.hardwareModel = hardwareModel
    self.settings = settings
    self.sheetCount = sheetCount
    self.reproduction = reproduction
  }

  public var text: String {
    var lines = [
      "Ganit problem report",
      "",
      "Describe what you did, what you expected, and what happened:",
      "",
      "",
      "App: \(appVersion)",
      "macOS: \(systemVersion)",
      "Mac: \(hardwareModel)",
      "Sheets: \(sheetCount)",
    ]
    lines += settings.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    lines += ["", "Reproduction:"]
    lines.append(reproduction ?? "(not included)")
    return lines.joined(separator: "\n") + "\n"
  }

  /// The Mac's model identifier, such as `MacBookPro18,2`.
  public static var hardwareModelIdentifier: String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}
