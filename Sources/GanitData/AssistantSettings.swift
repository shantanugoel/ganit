import Foundation
import Security

/// Where Ganit may send a line it could not work out, and whether it sends any
/// at all.
///
/// The endpoint is an OpenAI-compatible base, such as `https://host/v1`.
/// Ganit POSTs to `chat/completions` under it. A hosted model and one
/// running on this Mac are the same setting. Nothing is sent until someone
/// fills this in and turns it on.
public struct AssistantSettings: Equatable, Sendable {
  public static let defaultEndpoint = URL(string: "https://api.openai.com/v1")!
  public static let defaultModel = "gpt-4o-mini"

  public var isEnabled: Bool
  public var endpoint: URL
  public var model: String
  public var apiKey: String

  public init(
    isEnabled: Bool = false,
    endpoint: URL = AssistantSettings.defaultEndpoint,
    model: String = AssistantSettings.defaultModel,
    apiKey: String = ""
  ) {
    self.isEnabled = isEnabled
    self.endpoint = endpoint
    self.model = model
    self.apiKey = apiKey
  }

  /// Whether these settings name somewhere a line can actually be sent.
  public var isReady: Bool {
    isEnabled && Assistant.isAllowed(endpoint) && !model.isEmpty
  }

  // MARK: Storage

  private static let enabledKey = "AssistantAnswersUnknownLines"
  private static let endpointKey = "AssistantEndpoint"
  private static let modelKey = "AssistantModel"

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
      isEnabled: defaults.bool(forKey: enabledKey),
      endpoint: defaults.string(forKey: endpointKey).flatMap(URL.init(string:)) ?? defaultEndpoint,
      model: defaults.string(forKey: modelKey) ?? defaultModel
    )
  }

  func write(to defaults: UserDefaults) {
    defaults.set(isEnabled, forKey: Self.enabledKey)
    defaults.set(endpoint.absoluteString, forKey: Self.endpointKey)
    defaults.set(model, forKey: Self.modelKey)
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
