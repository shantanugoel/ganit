import Foundation

/// How hard Ganit asks a model to think.
///
/// The value goes out as `reasoning_effort` and the server decides what it
/// means, so Ganit names a preference rather than promising a behaviour.
/// **Off** names none at all and the model answers however it answers by
/// default; **Custom** is the way out for a server that wants a word Ganit has
/// never heard, such as `minimal` or `none`.
public enum AssistantEffort: Equatable, Hashable, Sendable {
  case off
  case low
  case medium
  case high
  case xhigh
  case max
  /// A word Ganit does not know, sent to the server as it was typed.
  case custom(String)

  /// The named levels, in the order Settings lists them. Custom is not one of
  /// them because it carries text rather than a level.
  public static let choices: [AssistantEffort] = [.off, .low, .medium, .high, .xhigh, .max]

  /// What someone gets who never touched the setting.
  public static let `default`: AssistantEffort = .medium

  /// Longer than this is a sentence, not a level.
  public static let maximumCustomLength = 32

  /// The word to send as `reasoning_effort`, or `nil` when Ganit sends no
  /// preference and the field is left out of the request entirely.
  public var wireValue: String? {
    switch self {
    case .off:
      return nil
    case .low:
      return "low"
    case .medium:
      return "medium"
    case .high:
      return "high"
    case .xhigh:
      return "xhigh"
    case .max:
      return "max"
    case .custom(let word):
      return word.isEmpty ? nil : word
    }
  }

  /// The text kept in preferences. A custom level is stored as `custom:<word>`
  /// so one key holds both which level was picked and what was typed.
  public var storageValue: String {
    switch self {
    case .off:
      return "off"
    case .low:
      return "low"
    case .medium:
      return "medium"
    case .high:
      return "high"
    case .xhigh:
      return "xhigh"
    case .max:
      return "max"
    case .custom(let word):
      return word.isEmpty ? "off" : "custom:\(word)"
    }
  }

  /// Whether this level wants something typed next to it.
  public var isCustom: Bool {
    if case .custom = self {
      return true
    }
    return false
  }

  /// Reads back what `storageValue` wrote. Anything Ganit does not
  /// recognise, including a level a newer Ganit invented, comes back as the
  /// default rather than as a preference nobody chose.
  public init(storage: String?) {
    guard let stored = storage?.trimmingCharacters(in: .whitespacesAndNewlines),
      !stored.isEmpty
    else {
      self = .default
      return
    }
    guard let rest = stored.stripPrefix("custom:") else {
      self = Self.choices.first { $0.storageValue == stored } ?? .default
      return
    }
    // One word, however the field was left. An empty one is the same as
    // asking for nothing.
    let word =
      rest
      .components(separatedBy: .whitespacesAndNewlines)
      .first { !$0.isEmpty }
      .map { String($0.prefix(Self.maximumCustomLength)) } ?? ""
    self = word.isEmpty ? .off : .custom(word)
  }
}

extension String {
  /// The part after `prefix`, or `nil` when the string does not start with it.
  fileprivate func stripPrefix(_ prefix: String) -> String? {
    guard hasPrefix(prefix) else {
      return nil
    }
    return String(dropFirst(prefix.count))
  }
}
