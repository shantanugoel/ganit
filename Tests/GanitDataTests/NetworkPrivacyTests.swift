import Foundation
import Network
import Testing

@testable import GanitData

@Suite
struct NetworkPrivacyTests {
  /// Sends the downloader's request to a loopback server and inspects the
  /// bytes that reach the wire, including headers the system adds.
  @Test
  func requestOnTheWireCarriesNoUserContentOrIdentifiers() async throws {
    let server = try LoopbackServer()
    defer { server.stop() }
    var request = RateDownloader.request
    request.url = URL(string: "http://127.0.0.1:\(server.port)\(RateSnapshot.sourceURL.path())")

    _ = try await RateDownloader().fetch(request)
    let raw = try #require(await server.request())
    let lines = raw.components(separatedBy: "\r\n")

    #expect(lines.first == "GET /stats/eurofxref/eurofxref-daily.xml HTTP/1.1")
    let headers = Dictionary(
      lines.dropFirst().prefix { !$0.isEmpty }.map { line -> (String, String) in
        let parts = line.split(separator: ":", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespaces)
        }
        return (parts[0].lowercased(), parts.count > 1 ? parts[1] : "")
      },
      uniquingKeysWith: { first, _ in first }
    )
    #expect(
      Set(headers.keys).isSubset(
        of: ["host", "accept", "user-agent", "accept-language", "accept-encoding", "connection"]),
      "\(headers.keys.sorted())")
    #expect(headers["accept"] == "text/xml")
    #expect(headers["user-agent"] == "Ganit")
    #expect(headers["accept-language"] == "*")
    #expect(raw.hasSuffix("\r\n\r\n"), "The request has no body")
    for identifier in [
      NSUserName(), ProcessInfo.processInfo.hostName,
      ProcessInfo.processInfo.operatingSystemVersionString,
      "Darwin", "CFNetwork", Locale.current.identifier,
    ] where identifier.count > 2 {
      #expect(!raw.localizedCaseInsensitiveContains(identifier), "\(identifier)")
    }
  }
}

@Test
func onlyTheRateDownloaderUsesTheNetwork() throws {
  let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources")
  let files = try #require(
    FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
  let networking = try files.filter { file in
    let source = try String(contentsOf: file, encoding: .utf8)
    return ["URLSession", "import Network", "NWConnection", "CFStream", "WKWebView"].contains {
      source.contains($0)
    }
  }
  #expect(networking.map(\.lastPathComponent) == ["RateDownloader.swift"])
}

/// A one-request HTTP server on a loopback port.
private final class LoopbackServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "LoopbackServer")
  private var received: String?
  private var waiters: [CheckedContinuation<String?, Never>] = []

  var port: UInt16 {
    listener.port?.rawValue ?? 0
  }

  init() throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { state in
      if case .ready = state {
        ready.signal()
      }
    }
    listener.newConnectionHandler = { [weak self] connection in
      self?.serve(connection)
    }
    listener.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
  }

  func stop() {
    listener.cancel()
  }

  func request() async -> String? {
    await withCheckedContinuation { continuation in
      queue.async {
        if let received = self.received {
          continuation.resume(returning: received)
        } else {
          self.waiters.append(continuation)
        }
      }
    }
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, _, _ in
      guard let self else {
        return
      }
      received = data.map { String(decoding: $0, as: UTF8.self) }
      for waiter in waiters {
        waiter.resume(returning: received)
      }
      waiters = []
      let body = "<ok/>"
      let response =
        "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: \(body.utf8.count)\r\n"
        + "Connection: close\r\n\r\n\(body)"
      connection.send(
        content: Data(response.utf8),
        completion: .contentProcessed { _ in
          connection.cancel()
        })
    }
  }
}
