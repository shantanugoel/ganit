import Foundation
import Testing

@testable import GanitEngine

@Suite
struct AssistanceValueTests {
  private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
  }

  @Test func preservesExactRationalAndDecimalScale() throws {
    let rational = try object(
      AssistanceNumber(
        .rational(RationalValue(numerator: IntegerValue(1), denominator: IntegerValue(3)))))
    #expect(rational["kind"] as? String == "rational")
    #expect(rational["numerator"] as? String == "1")
    #expect(rational["denominator"] as? String == "3")
    let decimal = try object(
      AssistanceNumber(.decimal(DecimalValue(coefficient: IntegerValue(12500), scale: 2))))
    #expect(decimal["coefficient"] as? String == "12500")
    #expect(decimal["scale"] as? Int == 2)
    let integer = try object(
      AssistanceNumber(.integer(IntegerValue("123456789012345678901234567890"))))
    #expect(integer["digits"] as? String == "123456789012345678901234567890")
  }

  @Test func preservesApproximationSourceAndErrorBound() throws {
    let value = try ApproximateValue(
      estimate: 0.333, source: .explicitRounding,
      precision: .absoluteErrorBound(DecimalValue(coefficient: IntegerValue(1), scale: 3)))
    let record = try object(AssistanceNumber(.approximate(value)))
    #expect(record["estimate"] as? Double == 0.333)
    #expect(record["source"] as? String == "explicitRounding")
    #expect(record["precision"] as? String == "absoluteErrorBound")
    let bound = try #require(record["errorBound"] as? [String: Any])
    #expect(bound["coefficient"] as? String == "1")
    #expect(bound["scale"] as? Int == 3)
  }

  @Test func preservesMoneyAndInstantZone() throws {
    let money = try object(
      AssistanceValue(.money(MoneyValue(amount: .integer(IntegerValue(2400)), currency: "INR"))))
    #expect(money["kind"] as? String == "money")
    #expect(money["currency"] as? String == "INR")
    let instant = try object(
      AssistanceValue(
        .instant(
          InstantValue(
            date: Date(timeIntervalSince1970: 1_770_000_000), timeZoneIdentifier: "Asia/Kolkata"))))
    #expect(instant["timeZone"] as? String == "Asia/Kolkata")
    #expect(instant["secondsSince1970"] as? Double == 1_770_000_000)
  }
  @Test func serializesQuantityDimensionsAndAffineTransform() throws {
    let engine = CalculationEngine()
    guard case .value(let density) = engine.evaluate("0.8 g/ml", context: try sheetContext()),
      case .value(let temperature) = engine.evaluate("20 °C", context: try sheetContext())
    else {
      Issue.record("Expected checked quantities")
      return
    }
    let record = try object(AssistanceValue(density))
    #expect(record["quantityKind"] as? String == "relative")
    let unit = try #require(record["unit"] as? [String: Any])
    let dimension = try #require(unit["dimension"] as? [String: Int])
    #expect(dimension == ["mass": 1, "length": -3])
    #expect(unit["scale"] != nil)
    #expect(unit["factors"] != nil)
    let absolute = try object(AssistanceValue(temperature))
    #expect(absolute["quantityKind"] as? String == "absolute")
    let affine = try #require(absolute["unit"] as? [String: Any])
    #expect(affine["kind"] as? String == "affine")
    #expect(affine["offset"] != nil)
  }

  @Test func preservesCalendarRateAndTemporalKinds() throws {
    let rate = try RateValue(
      amount: .percentage(PercentageValue(points: .integer(IntegerValue(6)))),
      denominator: .calendar(.year))
    let record = try object(AssistanceValue(.rate(rate)))
    #expect(record["amountKind"] as? String == "percentage")
    #expect(record["calendarPeriod"] as? String == "year")
    let points = try #require(record["points"] as? [String: Any])
    #expect(points["digits"] as? String == "6")
    let date = try object(AssistanceValue(.date(DateValue(year: 2024, month: 2, day: 29))))
    #expect(date["year"] as? Int == 2024)
    #expect(date["month"] as? Int == 2)
    #expect(date["day"] as? Int == 29)
    #expect(date["timeZone"] == nil)
    let time = try object(AssistanceValue(.time(LocalTimeValue(hour: 23, minute: 59, second: 58))))
    #expect(time["secondsSinceMidnight"] as? Int == 86_398)
    let period = try object(AssistanceValue(.period(CalendarPeriodValue(months: 1, days: 2))))
    #expect(period["months"] as? Int == 1)
    #expect(period["days"] as? Int == 2)
    let percentage = try object(
      AssistanceValue(.percentage(PercentageValue(points: .integer(IntegerValue(10))))))
    #expect(percentage["kind"] as? String == "percentage")
  }

}
