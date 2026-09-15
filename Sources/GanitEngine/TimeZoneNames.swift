import Foundation

/// Resolves IANA zone identifiers and a small set of city aliases.
///
/// Aliases are limited to large cities that lie in exactly one IANA zone.
/// Abbreviations such as `EST`, `IST`, or `CST` are excluded: each names more
/// than one offset or region, and a daylight-saving abbreviation would be
/// wrong for half the year.
enum TimeZoneNames {
  static let aliases: [String: String] = [
    "utc": "UTC", "gmt": "GMT",
    "london": "Europe/London", "dublin": "Europe/Dublin", "lisbon": "Europe/Lisbon",
    "paris": "Europe/Paris", "berlin": "Europe/Berlin", "madrid": "Europe/Madrid",
    "rome": "Europe/Rome", "amsterdam": "Europe/Amsterdam", "zurich": "Europe/Zurich",
    "stockholm": "Europe/Stockholm", "athens": "Europe/Athens", "istanbul": "Europe/Istanbul",
    "moscow": "Europe/Moscow", "cairo": "Africa/Cairo", "lagos": "Africa/Lagos",
    "nairobi": "Africa/Nairobi", "johannesburg": "Africa/Johannesburg",
    "dubai": "Asia/Dubai", "karachi": "Asia/Karachi", "mumbai": "Asia/Kolkata",
    "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "kolkata": "Asia/Kolkata",
    "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "dhaka": "Asia/Dhaka",
    "bangkok": "Asia/Bangkok", "jakarta": "Asia/Jakarta", "singapore": "Asia/Singapore",
    "hong kong": "Asia/Hong_Kong", "shanghai": "Asia/Shanghai", "beijing": "Asia/Shanghai",
    "taipei": "Asia/Taipei", "seoul": "Asia/Seoul", "tokyo": "Asia/Tokyo",
    "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne",
    "auckland": "Pacific/Auckland", "honolulu": "Pacific/Honolulu",
    "anchorage": "America/Anchorage", "vancouver": "America/Vancouver",
    "seattle": "America/Los_Angeles", "san francisco": "America/Los_Angeles",
    "los angeles": "America/Los_Angeles", "phoenix": "America/Phoenix",
    "denver": "America/Denver", "chicago": "America/Chicago",
    "mexico city": "America/Mexico_City", "toronto": "America/Toronto",
    "new york": "America/New_York", "boston": "America/New_York",
    "bogota": "America/Bogota", "lima": "America/Lima", "santiago": "America/Santiago",
    "buenos aires": "America/Argentina/Buenos_Aires", "sao paulo": "America/Sao_Paulo",
  ]

  /// Known IANA identifiers by their lowercased spelling.
  private static let identifiers: [String: String] = Dictionary(
    TimeZone.knownTimeZoneIdentifiers.map { ($0.lowercased(), $0) },
    uniquingKeysWith: { first, _ in first }
  )

  /// The IANA identifier for `America/New_York`-style identifiers, in any
  /// letter case, or for an alias whose words are joined by single spaces.
  static func identifier(for name: String) -> String? {
    let lowercased = name.lowercased()
    guard name.contains("/") else {
      return aliases[lowercased]
    }
    // The known list omits some current names, such as `Asia/Kolkata`.
    return TimeZone(identifier: name) != nil ? name : identifiers[lowercased]
  }
}
