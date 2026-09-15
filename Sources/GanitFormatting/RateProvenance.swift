import Foundation
import GanitEngine

/// How current downloaded rates are on a given day.
public enum RateFreshness: Equatable, Sendable {
  /// Published today.
  case current
  /// Published before a weekend that has not ended; every day since is a
  /// Saturday or Sunday.
  case weekendCarryForward(days: Int)
  case aged(days: Int)
  /// More than four calendar days old.
  case stale(days: Int)

  public static let staleAfterDays = 4

  /// The freshness of rates published on `observationDate`, `YYYY-MM-DD`, on
  /// the calendar day of `now` in `timeZone`.
  public init?(observationDate: String, now: Date, timeZone: TimeZone) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let parts = observationDate.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
      let observed = calendar.date(
        from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
      let days = calendar.dateComponents(
        [.day], from: observed, to: calendar.startOfDay(for: now)
      ).day
    else {
      return nil
    }
    if days <= 0 {
      self = .current
    } else if days > Self.staleAfterDays {
      self = .stale(days: days)
    } else if (1...days).allSatisfy({
      calendar.isDateInWeekend(calendar.date(byAdding: .day, value: $0, to: observed)!)
    }) {
      self = .weekendCarryForward(days: days)
    } else {
      self = .aged(days: days)
    }
  }
}

/// A labeled row of answer details.
public struct ProvenanceDetail: Hashable, Sendable {
  public let label: String
  public let value: String
}

/// Describes where a result's exchange rates came from.
public struct RateProvenanceFormatter: Sendable {
  private let context: EvaluationContext
  private let locale: Locale

  public init(context: EvaluationContext) {
    self.context = context
    locale = Locale(identifier: context.localeIdentifier)
  }

  /// Rows for a result that used these kinds of rate, or none when it used
  /// no rate. Reference rates always show their source, dates, status, and
  /// that they are indicative.
  public func details(for uses: Set<CurrencyRateUse>) -> [ProvenanceDetail] {
    var methods: [String] = []
    if uses.contains(.reference) {
      methods.append(localized("provenance.method.reference", defaultValue: "ECB reference rate"))
    }
    if uses.contains(.crossReference) {
      methods.append(
        localized(
          "provenance.method.crossReference",
          defaultValue: "Calculated by Ganit from ECB reference rates"))
    }
    if uses.contains(.manual) {
      methods.append(localized("provenance.method.manual", defaultValue: "Manual rate"))
    }
    guard !methods.isEmpty else {
      return []
    }
    var details = [
      ProvenanceDetail(
        label: localized("provenance.exchangeRate", defaultValue: "Exchange rate"),
        value: methods.joined(separator: "; "))
    ]
    let rates = context.currencyRates
    guard uses.contains(.reference) || uses.contains(.crossReference),
      let observationDate = rates.observationDate, let retrievedAt = rates.retrievedAt,
      let freshness = RateFreshness(
        observationDate: observationDate, now: context.now, timeZone: context.timeZone)
    else {
      return details
    }
    let published = DateFormatter()
    published.locale = locale
    published.timeZone = TimeZone(identifier: "UTC")
    published.dateStyle = .medium
    published.timeStyle = .none
    let publishedText =
      ISO8601DateFormatter.fullDate.date(from: observationDate).map(published.string(from:))
      ?? observationDate
    let retrieved = DateFormatter()
    retrieved.locale = locale
    retrieved.timeZone = context.timeZone
    retrieved.dateStyle = .medium
    retrieved.timeStyle = .short
    details += [
      ProvenanceDetail(
        label: localized("provenance.source", defaultValue: "Source"),
        value: localized("provenance.source.ecb", defaultValue: "ECB statistics")),
      ProvenanceDetail(
        label: localized("provenance.published", defaultValue: "Rates published"),
        value: publishedText),
      ProvenanceDetail(
        label: localized("provenance.retrieved", defaultValue: "Retrieved"),
        value: retrieved.string(from: retrievedAt)),
      ProvenanceDetail(
        label: localized("provenance.status", defaultValue: "Rate status"),
        value: status(freshness)),
      ProvenanceDetail(
        label: localized("provenance.note", defaultValue: "Note"),
        value: localized(
          "provenance.indicative", defaultValue: "Indicative, not for transactions")),
    ]
    return details
  }

  private func status(_ freshness: RateFreshness) -> String {
    switch freshness {
    case .current:
      return localized("provenance.status.current", defaultValue: "Current")
    case .weekendCarryForward(let days):
      return localized(
        "provenance.status.weekend", defaultValue: "Weekend rates, \(days) days old")
    case .aged(let days):
      return localized("provenance.status.aged", defaultValue: "\(days) days old")
    case .stale(let days):
      return localized("provenance.status.stale", defaultValue: "Stale, \(days) days old")
    }
  }

  private func localized(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: defaultValue, bundle: .module, locale: locale)
  }
}

extension ISO8601DateFormatter {
  fileprivate static var fullDate: ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter
  }
}
