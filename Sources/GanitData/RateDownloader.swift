import Foundation

/// Downloads the ECB feed with a request that carries nothing about the user:
/// no cookies, cache, credentials, or query, and no redirect off the ECB host.
public final class RateDownloader: NSObject, URLSessionTaskDelegate, Sendable {
  private let session: URLSession

  public override init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30
    session = URLSession(configuration: configuration)
    super.init()
  }

  /// The only request Ganit sends for currency data.
  public static var request: URLRequest {
    var request = URLRequest(url: RateSnapshot.sourceURL)
    request.setValue("text/xml", forHTTPHeaderField: "Accept")
    return request
  }

  /// Downloads and validates the current publication.
  public func download(retrievedAt now: @Sendable () -> Date = Date.init) async throws
    -> RateSnapshot
  {
    let (data, response) = try await session.data(for: Self.request, delegate: self)
    return try ECBRateValidator.snapshot(from: data, response: response, retrievedAt: now())
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    ECBRateValidator.isAllowed(request.url) ? request : nil
  }
}
