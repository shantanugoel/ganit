/// The finance functions, which are the same compounding arithmetic a person
/// would write by hand, with a name instead of the formula.
///
/// Each takes an amount, a rate for one period, and a whole number of
/// periods. The rate is per period rather than per year, and a payment falls
/// at the end of its period; a result says so, because a finance answer means
/// nothing without its assumptions.
public enum FinanceFunction: String, CaseIterable, Hashable, Sendable {
  /// `fv(1,000, 5%, 10)`: what an amount grows to.
  case futureValue = "fv"
  /// `pv(1,000, 5%, 10)`: what a later amount is worth now.
  case presentValue = "pv"
  /// `pmt(300,000, 0.5%, 360)`: the equal payment that repays an amount.
  case payment = "pmt"

  static let argumentCount = 3
}
