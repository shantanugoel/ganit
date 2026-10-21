import Foundation
import Network

/// A loopback HTTP server that answers every request it is sent, keeps the
/// bytes of each one so a test can read what went over the wire, and can be
/// told to refuse a request that names something it does not know.
final class LoopbackServer: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "LoopbackServer")
  private let body: String
  private let contentType: String
  private let responder: @Sendable (String) -> (status: Int, body: String)
  private var received: [String] = []
  private var waiters: [(atLeast: Int, continuation: CheckedContinuation<[String], Never>)] = []

  var port: UInt16 {
    listener.port?.rawValue ?? 0
  }

  init(
    body: String = "<ok/>", contentType: String = "text/xml",
    responder: (@Sendable (String) -> (status: Int, body: String))? = nil
  ) throws {
    self.body = body
    self.contentType = contentType
    self.responder = responder ?? { _ in (200, body) }
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

  /// Every request served so far, in the order they arrived. Waits for at
  /// least one.
  func request() async -> String? {
    await requests().first
  }

  /// Every request served so far, waiting until at least `count` have
  /// arrived. A retried request is the whole point of some tests.
  func requests(atLeast count: Int = 1) async -> [String] {
    await withCheckedContinuation { continuation in
      queue.async {
        if self.received.count >= count {
          continuation.resume(returning: self.received)
        } else {
          self.waiters.append((count, continuation))
        }
      }
    }
  }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, so: "")
  }

  /// Reads until the request's headers, and the body its `Content-Length`
  /// promises, have arrived; a body may follow its headers in a later packet.
  private func read(_ connection: NWConnection, so far: String) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [weak self] data, _, isComplete, _ in
      guard let self else {
        return
      }
      let raw = far + (data.map { String(decoding: $0, as: UTF8.self) } ?? "")
      guard isComplete || isWhole(raw) else {
        return read(connection, so: raw)
      }
      received.append(raw)
      let waiting = waiters
      waiters = waiting.filter { $0.atLeast > received.count }
      for waiter in waiting where waiter.atLeast <= received.count {
        waiter.continuation.resume(returning: received)
      }
      let answer = responder(raw)
      let response =
        "HTTP/1.1 \(answer.status) \(answer.status == 200 ? "OK" : "Refused")\r\n"
        + "Content-Type: \(contentType)\r\nContent-Length: \(answer.body.utf8.count)\r\n"
        + "Connection: close\r\n\r\n\(answer.body)"
      connection.send(
        content: Data(response.utf8),
        completion: .contentProcessed { _ in
          connection.cancel()
        })
    }
  }

  private func isWhole(_ raw: String) -> Bool {
    guard let separator = raw.range(of: "\r\n\r\n") else {
      return false
    }
    let length = raw[raw.startIndex..<separator.lowerBound]
      .components(separatedBy: "\r\n")
      .first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) }
    return raw[separator.upperBound...].utf8.count >= (length ?? 0)
  }
}
