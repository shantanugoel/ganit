import Foundation
import Testing

@testable import GanitData

/// An ECB daily feed with `rates` in publication order.
func ecbPayload(date: String = "2026-09-14", rates: [(String, String)] = standardRates) -> Data {
  let cubes = rates.map { "\t\t\t<Cube currency='\($0.0)' rate='\($0.1)'/>" }.joined(
    separator: "\n")
  return Data(
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
    \t<gesmes:subject>Reference rates</gesmes:subject>
    \t<gesmes:Sender>
    \t\t<gesmes:name>European Central Bank</gesmes:name>
    \t</gesmes:Sender>
    \t<Cube>
    \t\t<Cube time='\(date)'>
    \(cubes)
    \t\t</Cube>
    \t</Cube>
    </gesmes:Envelope>
    """.utf8)
}

let standardRates = [
  ("USD", "1.1551"), ("JPY", "178.52"), ("CZK", "24.294"), ("DKK", "7.4753"), ("GBP", "0.85598"),
  ("HUF", "365.33"), ("PLN", "4.3418"), ("RON", "5.0893"), ("SEK", "10.9920"), ("CHF", "0.9318"),
  ("ISK", "143.60"), ("NOK", "11.6030"), ("TRY", "49.4051"), ("AUD", "1.7519"), ("BRL", "6.2560"),
  ("CAD", "1.6031"), ("CNY", "8.2270"), ("HKD", "8.9920"), ("IDR", "19030.52"), ("ILS", "3.8780"),
  ("INR", "101.8120"), ("KRW", "1611.39"), ("MXN", "21.4430"), ("MYR", "4.8750"),
  ("NZD", "1.9760"), ("PHP", "65.867"), ("SGD", "1.4910"), ("THB", "37.071"), ("ZAR", "20.3880"),
]

func ecbResponse(
  status: Int = 200,
  url: URL = RateSnapshot.sourceURL,
  mimeType: String = "text/xml"
) -> HTTPURLResponse {
  HTTPURLResponse(
    url: url, statusCode: status, httpVersion: "HTTP/2",
    headerFields: ["Content-Type": mimeType])!
}

let retrievalTime = Date(timeIntervalSince1970: 1_789_480_000.75)

@Suite
struct ECBRateValidatorTests {
  @Test
  func acceptsThePublishedFeedWithoutChangingItsDecimals() throws {
    let payload = ecbPayload()
    let snapshot = try ECBRateValidator.snapshot(
      from: payload, response: ecbResponse(), retrievedAt: retrievalTime)

    #expect(snapshot.payload == payload)
    #expect(snapshot.metadata.observationDate == "2026-09-14")
    #expect(snapshot.metadata.rates.count == standardRates.count)
    #expect(snapshot.metadata.rates["SEK"] == "10.9920")
    #expect(snapshot.metadata.provider == "ecb")
    #expect(snapshot.metadata.retrievedAt == Date(timeIntervalSince1970: 1_789_480_000))
    #expect(snapshot.metadata.payloadChecksum.hasPrefix("sha256:"))
    #expect(snapshot.isIntact)
    #expect(snapshot.id.hasPrefix("2026-09-14-"))
  }

  @Test
  func rejectsUnexpectedResponses() {
    let payload = ecbPayload()
    let cases: [(HTTPURLResponse, Data, RateValidationError)] = [
      (ecbResponse(status: 304), payload, .unexpectedStatus(304)),
      (
        ecbResponse(url: URL(string: "https://example.com/eurofxref-daily.xml")!), payload,
        .disallowedURL
      ),
      (
        ecbResponse(
          url: URL(string: "http://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!),
        payload, .disallowedURL
      ),
      (ecbResponse(mimeType: "text/html"), payload, .unexpectedMIMEType("text/html")),
      (ecbResponse(), Data(count: 70_000), .payloadTooLarge(70_000)),
    ]
    for (response, data, error) in cases {
      #expect(throws: error) {
        try ECBRateValidator.snapshot(from: data, response: response, retrievedAt: retrievalTime)
      }
    }
  }

  @Test
  func rejectsPayloadsThatCouldChangeRatesOrTheirDate() {
    var duplicate = standardRates
    duplicate.append(("USD", "1.2"))
    var euro = standardRates
    euro.append(("EUR", "1"))
    let cases: [(Data, RateValidationError)] = [
      (Data("<html>maintenance</html>".utf8), .malformedPayload),
      (Data(ecbPayload().prefix(400)), .malformedPayload),
      (ecbPayload(rates: duplicate), .duplicateCurrency("USD")),
      (ecbPayload(rates: euro), .invalidCurrency("EUR")),
      (ecbPayload(rates: [("usd", "1.1")] + standardRates), .invalidCurrency("usd")),
      (ecbPayload(rates: [("XAU", "1e3")] + standardRates), .invalidRate(currency: "XAU")),
      (ecbPayload(rates: [("XAU", "-1.2")] + standardRates), .invalidRate(currency: "XAU")),
      (ecbPayload(rates: [("XAU", "1.")] + standardRates), .invalidRate(currency: "XAU")),
      (
        ecbPayload(rates: [("XAU", "0.00000001")] + standardRates),
        .implausibleRate(currency: "XAU")
      ),
      (ecbPayload(rates: Array(standardRates.prefix(10))), .missingCurrencies),
      (ecbPayload(rates: standardRates.filter { $0.0 != "JPY" }), .missingCurrencies),
      (ecbPayload(date: "2026-02-30"), .invalidObservationDate),
      (ecbPayload(date: "2026-9-14"), .invalidObservationDate),
      (ecbPayload(date: "2026-09-17"), .invalidObservationDate),
    ]
    for (payload, error) in cases {
      #expect(throws: error) {
        try ECBRateValidator.snapshot(
          from: payload, response: ecbResponse(), retrievedAt: retrievalTime)
      }
    }
  }

  @Test
  func requestCarriesOnlyTheFixedURLAndAcceptHeader() {
    let request = RateDownloader.request
    #expect(request.url == RateSnapshot.sourceURL)
    #expect(request.httpMethod == "GET")
    #expect(request.allHTTPHeaderFields == ["Accept": "text/xml"])
    #expect(request.httpBody == nil)
  }
}
