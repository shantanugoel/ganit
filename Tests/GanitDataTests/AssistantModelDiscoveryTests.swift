import Foundation
import Testing

@testable import GanitData

@Suite
struct AssistantModelDiscoveryTests {
  private func settings(
    _ server: LoopbackServer, provider: AssistantProvider = .custom, key: String = ""
  ) -> AssistantSettings {
    AssistantSettings(
      provider: provider,
      endpoint: URL(string: "http://127.0.0.1:\(server.port)/prefix/v1/chat/completions/")!,
      model: "keep-me", apiKey: key)
  }

  @Test func discoveryUsesGETAndOnlyConnectionCredentials() async throws {
    let server = try LoopbackServer(
      body:
        #"{"data":[{"id":"one","name":"First","pricing":{"unused":true}},{"id":"one"},{"id":"two"}],"extra":true}"#,
      contentType: "application/json")
    defer { server.stop() }
    let saved = settings(server, provider: .openRouter, key: "fixture-key")
    let result = try await ProviderModelDiscovery().models(settings: saved)
    #expect(result == [AssistantModel(id: "one", name: "First"), AssistantModel(id: "two")])
    #expect(saved.model == "keep-me")
    let raw = try #require(await server.request())
    #expect(raw.hasPrefix("GET /prefix/v1/models/user HTTP/1.1"))
    #expect(raw.lowercased().contains("authorization: bearer fixture-key"))
    #expect(raw.lowercased().contains("user-agent: ganit"))
    #expect(raw.hasSuffix("\r\n\r\n"))
    #expect(!raw.contains("keep-me"))
    #expect(!raw.lowercased().contains("cookie:"))
    #expect(await server.requestCount() == 1)
  }

  @Test func discoverySupportsBoundedPaginationAndEmptyListsWithoutKeys() async throws {
    let server = try LoopbackServer(contentType: "application/json") { request in
      if request.contains("after=first") {
        return (200, #"{"data":[{"id":"first"},{"id":"last"}],"has_more":false}"#)
      }
      return (200, #"{"data":[{"id":"first"}],"has_more":true,"last_id":"first"}"#)
    }
    defer { server.stop() }
    let list = try await ProviderModelDiscovery().models(
      settings: settings(server, provider: .lmStudio))
    #expect(list.map(\.id) == ["first", "last"])
    let requests = await server.requests(atLeast: 2)
    #expect(requests[1].hasPrefix("GET /prefix/v1/models?after=first HTTP/1.1"))
    #expect(
      requests.allSatisfy {
        !$0.lowercased().contains("authorization:") && $0.hasSuffix("\r\n\r\n")
      })
    let empty = try LoopbackServer(body: #"{"data":[]}"#)
    defer { empty.stop() }
    #expect(try await ProviderModelDiscovery().models(settings: settings(empty)).isEmpty)
  }

  @Test func repeatedCursorsMalformedListsAndLargeBodiesFail() async throws {
    let repeatPage = try LoopbackServer(body: #"{"data":[{"id":"same"}],"has_more":true}"#)
    defer { repeatPage.stop() }
    await #expect(throws: AssistantModelDiscoveryError.invalidList) {
      try await ProviderModelDiscovery().models(settings: settings(repeatPage))
    }
    #expect(await repeatPage.requestCount() == 2)
    for body in [#"{"models":[]}"#, #"{"data":[{"name":"missing id"}]}"#] {
      let malformed = try LoopbackServer(body: body)
      defer { malformed.stop() }
      await #expect(throws: AssistantModelDiscoveryError.invalidList) {
        try await ProviderModelDiscovery().models(settings: settings(malformed))
      }
    }
    let large = try LoopbackServer(
      body: String(repeating: "x", count: ProviderModelDiscovery.pageBytes + 1))
    defer { large.stop() }
    await #expect(throws: SuggestionTransportError.payloadTooLarge) {
      try await ProviderModelDiscovery().models(settings: settings(large))
    }
  }

  @Test func discoveryRefusesRedirectsAndReportsProviderErrors() async throws {
    let target = try LoopbackServer(body: #"{"data":[]}"#)
    defer { target.stop() }
    let redirect = try LoopbackServer(
      status: 302, headers: ["Location": "http://127.0.0.1:\(target.port)/stolen"])
    defer { redirect.stop() }
    do {
      _ = try await ProviderModelDiscovery().models(settings: settings(redirect, key: "secret"))
      Issue.record("Expected a redirect failure")
    } catch let failure as ProviderFailure { #expect(failure.status == 302) }
    #expect(await target.requestCount() == 0)
    let rejected = try LoopbackServer(
      body: #"{"error":{"code":"invalid_api_key","message":"secret"}}"#, status: 401)
    defer { rejected.stop() }
    do {
      _ = try await ProviderModelDiscovery().models(settings: settings(rejected, key: "secret"))
      Issue.record("Expected authentication failure")
    } catch let failure as ProviderFailure {
      #expect(failure.category == .authentication)
      #expect(failure.code == "invalid_api_key")
      #expect(failure.status == 401)
      #expect(!String(describing: failure).contains("secret"))
    }
  }

  @Test func cancelledDiscoveryMakesNoRequest() async throws {
    let server = try LoopbackServer(body: #"{"data":[]}"#)
    defer { server.stop() }
    let connection = settings(server)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ProviderModelDiscovery().models(settings: connection)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await server.requestCount() == 0)
  }
}
