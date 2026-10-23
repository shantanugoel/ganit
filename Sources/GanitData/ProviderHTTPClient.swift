import Foundation

/// Both provider operations use the same address, redirect, and privacy rules.
final class ProviderHTTPClient: NSObject, URLSessionTaskDelegate, Sendable {
  func send(_ request: URLRequest, limit: Int) async throws -> (Data, Int) {
    try Task.checkCancellation()
    guard let url = request.url, Assistant.isAllowed(url) else {
      throw SuggestionTransportError.disallowedURL
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = request.timeoutInterval
    configuration.timeoutIntervalForResource = request.timeoutInterval
    configuration.httpAdditionalHeaders = ["User-Agent": "Ganit", "Accept-Language": "*"]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: request, delegate: self)
    guard let response = response as? HTTPURLResponse else {
      throw SuggestionTransportError.malformedCompletion
    }
    guard response.expectedContentLength <= limit else {
      throw SuggestionTransportError.payloadTooLarge
    }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < limit else { throw SuggestionTransportError.payloadTooLarge }
      data.append(byte)
    }
    try Task.checkCancellation()
    return (data, response.statusCode)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? { nil }
}
