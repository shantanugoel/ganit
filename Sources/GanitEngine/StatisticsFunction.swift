/// The statistics a line can take over values it lists itself, such as
/// `median(3, 9, 4)`.
///
/// They are the same arithmetic as the aggregates that read the lines above, so
/// a list of money answers in its currency and a mixed list fails, exactly as
/// `total` does. Which values are included is the only difference.
public enum StatisticsFunction: String, Hashable, Sendable {
  case sum
  case total
  case average
  case avg
  case median
  case count

  var aggregate: Aggregate {
    switch self {
    case .sum, .total:
      return .sum
    case .average, .avg:
      return .average
    case .median:
      return .median
    case .count:
      return .count
    }
  }
}
