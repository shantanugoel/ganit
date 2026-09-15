import Foundation

public enum RateValidationError: Error, Equatable, Sendable {
  case unexpectedStatus(Int)
  case disallowedURL
  case unexpectedMIMEType(String?)
  case payloadTooLarge(Int)
  case malformedPayload
  case invalidObservationDate
  case invalidCurrency(String)
  case duplicateCurrency(String)
  case invalidRate(currency: String)
  case implausibleRate(currency: String)
  case missingCurrencies
}

/// Accepts only a complete, well-formed ECB daily reference-rate response.
public enum ECBRateValidator {
  public static let allowedHost = "www.ecb.europa.eu"
  public static let maximumPayloadBytes = 64 * 1_024
  /// Currencies every publication has quoted since the euro began.
  static let requiredCurrencies: Set<String> = ["USD", "JPY", "GBP", "CHF"]
  static let minimumCurrencyCount = 20
  /// Units per euro; wider than any ECB quote.
  static let plausibleRates = 0.0001...1_000_000.0

  public static func isAllowed(_ url: URL?) -> Bool {
    url?.scheme == "https" && url?.host() == allowedHost
  }

  /// Validates a response and its body into a snapshot retrieved at `now`.
  public static func snapshot(
    from payload: Data,
    response: URLResponse,
    retrievedAt now: Date
  ) throws -> RateSnapshot {
    guard let response = response as? HTTPURLResponse else {
      throw RateValidationError.malformedPayload
    }
    guard response.statusCode == 200 else {
      throw RateValidationError.unexpectedStatus(response.statusCode)
    }
    guard isAllowed(response.url) else {
      throw RateValidationError.disallowedURL
    }
    guard ["text/xml", "application/xml"].contains(response.mimeType) else {
      throw RateValidationError.unexpectedMIMEType(response.mimeType)
    }
    guard payload.count <= maximumPayloadBytes else {
      throw RateValidationError.payloadTooLarge(payload.count)
    }
    let (date, rates) = try parse(payload)
    try validate(date: date, now: now)
    guard rates.count >= minimumCurrencyCount, requiredCurrencies.isSubset(of: rates.keys) else {
      throw RateValidationError.missingCurrencies
    }
    return RateSnapshot(
      metadata: RateSnapshotMetadata(
        provider: RateSnapshot.providerIdentifier,
        sourceURL: RateSnapshot.sourceURL,
        observationDate: date,
        // Metadata stores whole seconds.
        retrievedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)),
        payloadChecksum: sha256(payload),
        rates: rates
      ),
      payload: payload
    )
  }

  private static func parse(_ payload: Data) throws -> (date: String, rates: [String: String]) {
    let delegate = ParserDelegate()
    let parser = XMLParser(data: payload)
    parser.shouldResolveExternalEntities = false
    parser.delegate = delegate
    guard parser.parse(), delegate.isEnvelope else {
      throw delegate.error ?? RateValidationError.malformedPayload
    }
    guard delegate.dates.count == 1 else {
      throw RateValidationError.malformedPayload
    }
    return (delegate.dates[0], delegate.rates)
  }

  private static func validate(date: String, now: Date) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    // A publication cannot be dated after the current date anywhere on Earth.
    guard let observed = formatter.date(from: date), formatter.string(from: observed) == date,
      observed <= now.addingTimeInterval(14 * 3_600)
    else {
      throw RateValidationError.invalidObservationDate
    }
  }

  /// Digits with at most one decimal point and digits on both sides.
  static func isDecimal(_ text: String) -> Bool {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count <= 2 && text.utf8.count <= 20
      && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }
  }

  /// Collects the dated cube and its currency cubes, stopping at the first
  /// element that could change their meaning.
  private final class ParserDelegate: NSObject, XMLParserDelegate {
    var isEnvelope = false
    var dates: [String] = []
    var rates: [String: String] = [:]
    var error: RateValidationError?

    func parser(
      _ parser: XMLParser,
      didStartElement elementName: String,
      namespaceURI: String?,
      qualifiedName: String?,
      attributes: [String: String] = [:]
    ) {
      if elementName == "gesmes:Envelope" {
        isEnvelope = true
      }
      guard elementName == "Cube" else {
        return
      }
      if let time = attributes["time"] {
        dates.append(time)
        return
      }
      guard let currency = attributes["currency"] else {
        return
      }
      guard dates.count == 1, let rate = attributes["rate"] else {
        return fail(.malformedPayload, parser)
      }
      guard currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }),
        currency != "EUR"
      else {
        return fail(.invalidCurrency(currency), parser)
      }
      guard rates[currency] == nil else {
        return fail(.duplicateCurrency(currency), parser)
      }
      guard ECBRateValidator.isDecimal(rate), let value = Double(rate) else {
        return fail(.invalidRate(currency: currency), parser)
      }
      guard plausibleRates.contains(value) else {
        return fail(.implausibleRate(currency: currency), parser)
      }
      rates[currency] = rate
    }

    private func fail(_ error: RateValidationError, _ parser: XMLParser) {
      self.error = error
      parser.abortParsing()
    }
  }
}
