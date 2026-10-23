import Foundation

public struct AssistantModel: Decodable, Equatable, Sendable {
  public let id: String
  public let name: String?

  public init(id: String, name: String? = nil) {
    self.id = id
    self.name = name
  }
}

/// Discovery has no sheet context and does not use the Ask request budget.
public protocol AssistantModelDiscovery: Sendable {
  func models(settings: AssistantSettings) async throws -> [AssistantModel]
}

public enum AssistantModelDiscoveryError: Error, Equatable {
  case invalidList, limit
}

public struct ProviderModelDiscovery: AssistantModelDiscovery {
  public init() {}
  static let pageBytes = 2 * 1024 * 1024
  static let totalBytes = 8 * 1024 * 1024

  public func models(settings: AssistantSettings) async throws -> [AssistantModel] {
    let authorization = try settings.provider.authorization(apiKey: settings.apiKey)
    let base = settings.provider.modelsURL(settings.endpoint)
    guard Assistant.isAllowed(base) else { throw SuggestionTransportError.disallowedURL }
    var url = base
    var models: [AssistantModel] = []
    var identifiers: Set<String> = []
    var cursors: Set<String> = []
    var bytes = 0
    for _ in 0..<32 {
      try Task.checkCancellation()
      var request = URLRequest(url: url, timeoutInterval: 30)
      request.httpMethod = "GET"
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      request.setValue(authorization, forHTTPHeaderField: "Authorization")
      let (data, status) = try await ProviderHTTPClient().send(request, limit: Self.pageBytes)
      bytes += data.count
      guard bytes <= Self.totalBytes else { throw AssistantModelDiscoveryError.limit }
      if let failure = ProviderFailure.decode(data, status: status, requireError: status != 200) {
        throw failure
      }
      let page: Page
      do { page = try JSONDecoder().decode(Page.self, from: data) } catch {
        throw AssistantModelDiscoveryError.invalidList
      }
      for model in page.data where !model.id.isEmpty && identifiers.insert(model.id).inserted {
        guard models.count < 10_000 else { throw AssistantModelDiscoveryError.limit }
        models.append(model)
      }
      guard page.hasMore == true else { return models }
      guard let cursor = page.lastID ?? page.data.last?.id, !cursor.isEmpty,
        cursors.insert(cursor).inserted
      else { throw AssistantModelDiscoveryError.invalidList }
      // Retain the endpoint and origin. Never follow a server-supplied URL.
      var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
      var query = (parts.queryItems ?? []).filter { $0.name != "after" }
      query.append(URLQueryItem(name: "after", value: cursor))
      parts.queryItems = query
      url = parts.url!
    }
    throw AssistantModelDiscoveryError.limit
  }

  private struct Page: Decodable {
    let data: [AssistantModel]
    let hasMore: Bool?
    let lastID: String?
    enum CodingKeys: String, CodingKey {
      case data
      case hasMore = "has_more"
      case lastID = "last_id"
    }
  }
}
