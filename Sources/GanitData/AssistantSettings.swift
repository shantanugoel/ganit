import Foundation
import Security

/// The provider settings for explicit Ask requests.
///
/// The endpoint is a Chat Completions API base or a full generation URL.
/// A request starts only after an explicit Ask or Fetch Models action.
public struct AssistantSettings: Equatable, Sendable {
  public static let defaultEndpoint = URL(string: "https://api.openai.com/v1")!
  public static let defaultModel = "gpt-4o-mini"
  public static let markAIDerivedAnswersKey = "AssistantMarkAIDerivedAnswers"
  /// How long one Ask request may take. A model that thinks before it answers
  /// is slow on any address, so the wait is one number rather than one per
  /// kind of host.
  public static let defaultResponseTimeout: TimeInterval = 120
  /// The shortest wait worth offering: below it a request fails on its way
  /// through the network stack rather than on the model.
  public static let minimumResponseTimeout: TimeInterval = 5
  public static let maximumResponseTimeout: TimeInterval = 600

  public var provider: AssistantProvider
  public var isEnabled: Bool
  public var endpoint: URL
  public var model: String
  public var apiKey: String
  public var markAIDerivedAnswers: Bool
  /// How hard the model is asked to think. `AssistantEffort.default` is what
  /// someone gets who never opened Settings.
  public var effort: AssistantEffort
  /// The maximum automatic repair attempts for one Ask. The request limit can
  /// reduce this number.
  public var repairAttempts: Int {
    didSet { repairAttempts = min(3, max(0, repairAttempts)) }
  }
  /// Seconds one Ask request waits for its reply. Each request keeps the
  /// value it was created with, so a change applies to the next Ask.
  public var responseTimeout: TimeInterval {
    didSet { responseTimeout = Self.clamped(responseTimeout) }
  }

  static func clamped(_ timeout: TimeInterval) -> TimeInterval {
    guard timeout.isFinite else { return defaultResponseTimeout }
    return min(maximumResponseTimeout, max(minimumResponseTimeout, timeout))
  }

  public init(
    provider: AssistantProvider = .custom,
    isEnabled: Bool = false,
    endpoint: URL? = nil,
    model: String = AssistantSettings.defaultModel,
    apiKey: String = "",
    effort: AssistantEffort = .default,
    repairAttempts: Int = 2,
    responseTimeout: TimeInterval = AssistantSettings.defaultResponseTimeout,
    markAIDerivedAnswers: Bool = true
  ) {
    self.provider = provider
    self.isEnabled = isEnabled
    self.endpoint = endpoint ?? provider.defaultEndpoint ?? Self.defaultEndpoint
    self.model = model
    self.apiKey = apiKey
    self.markAIDerivedAnswers = markAIDerivedAnswers
    self.effort = effort
    self.repairAttempts = min(3, max(0, repairAttempts))
    self.responseTimeout = Self.clamped(responseTimeout)
  }

  /// Whether Ask can use this provider.
  public var isReady: Bool {
    isEnabled && Assistant.isAllowed(endpoint) && !model.isEmpty
      && (!provider.requiresKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  // MARK: Storage

  private static let providerKey = "AssistantProvider"
  private static let enabledKey = "AssistantAnswersUnknownLines"
  private static let endpointKey = "AssistantEndpoint"
  private static let modelKey = "AssistantModel"
  private static let effortKey = "AssistantEffort"
  private static let repairAttemptsKey = "AssistantRepairAttempts"
  private static let responseTimeoutKey = "AssistantResponseTimeout"

  /// Preferences say where to ask; the keychain holds the key.
  public static func load(from defaults: UserDefaults = .standard) -> AssistantSettings {
    var settings = read(from: defaults)
    settings.apiKey = AssistantKey.load()
    return settings
  }

  public func save(to defaults: UserDefaults = .standard) {
    write(to: defaults)
    AssistantKey.save(apiKey)
  }

  static func read(from defaults: UserDefaults) -> AssistantSettings {
    AssistantSettings(
      provider: defaults.string(forKey: providerKey).flatMap(AssistantProvider.init(rawValue:))
        ?? .custom,
      isEnabled: defaults.bool(forKey: enabledKey),
      endpoint: defaults.string(forKey: endpointKey).flatMap(URL.init(string:)) ?? defaultEndpoint,
      model: defaults.string(forKey: modelKey) ?? defaultModel,
      effort: AssistantEffort(storage: defaults.string(forKey: effortKey)),
      repairAttempts: defaults.object(forKey: repairAttemptsKey) as? Int ?? 2,
      responseTimeout: (defaults.object(forKey: responseTimeoutKey) as? NSNumber).map {
        doubleValue in
        AssistantSettings.clamped(doubleValue.doubleValue)
      } ?? defaultResponseTimeout,
      markAIDerivedAnswers: defaults.object(forKey: markAIDerivedAnswersKey) as? Bool ?? true
    )
  }

  func write(to defaults: UserDefaults) {
    defaults.set(provider.rawValue, forKey: Self.providerKey)
    defaults.set(isEnabled, forKey: Self.enabledKey)
    defaults.set(endpoint.absoluteString, forKey: Self.endpointKey)
    defaults.set(model, forKey: Self.modelKey)
    defaults.set(effort.storageValue, forKey: Self.effortKey)
    defaults.set(repairAttempts, forKey: Self.repairAttemptsKey)
    defaults.set(responseTimeout, forKey: Self.responseTimeoutKey)
    defaults.set(markAIDerivedAnswers, forKey: Self.markAIDerivedAnswersKey)
  }
}

/// The assistant's API key, kept in the keychain rather than in preferences,
/// which are a plain file any process running as this user can read.
enum AssistantKey {
  private static let service = "Ganit Assistant"
  private static let account = "api-key"

  private static var query: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  static func load() -> String {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data
    else {
      return ""
    }
    return String(decoding: data, as: UTF8.self)
  }

  static func save(_ key: String) {
    SecItemDelete(query as CFDictionary)
    guard !key.isEmpty else {
      return
    }
    var item = query
    item[kSecValueData as String] = Data(key.utf8)
    // The key is only needed while someone is using the Mac it was typed on.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    SecItemAdd(item as CFDictionary, nil)
  }
}
