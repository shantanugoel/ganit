public struct SyntaxLimits: Equatable, Sendable {
  public let maximumSourceUTF8Length: Int
  public let maximumTokenCount: Int
  public let maximumParseDepth: Int

  public init(
    maximumSourceUTF8Length: Int = 1_048_576,
    maximumTokenCount: Int = 100_000,
    maximumParseDepth: Int = 128
  ) {
    precondition(maximumSourceUTF8Length > 0)
    precondition(maximumTokenCount > 0)
    precondition(maximumParseDepth > 0)
    self.maximumSourceUTF8Length = maximumSourceUTF8Length
    self.maximumTokenCount = maximumTokenCount
    self.maximumParseDepth = maximumParseDepth
  }

  public static let `default` = SyntaxLimits()
}
