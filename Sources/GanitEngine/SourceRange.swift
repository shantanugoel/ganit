public struct SourceRange: Hashable, Sendable {
  /// Half-open lower bound measured in UTF-8 code units.
  public let lowerBound: Int
  /// Half-open upper bound measured in UTF-8 code units.
  public let upperBound: Int
  /// Half-open lower bound measured in extended grapheme clusters.
  public let graphemeLowerBound: Int
  /// Half-open upper bound measured in extended grapheme clusters.
  public let graphemeUpperBound: Int

  package init(
    lowerBound: Int,
    upperBound: Int,
    graphemeLowerBound: Int,
    graphemeUpperBound: Int
  ) {
    precondition(lowerBound >= 0)
    precondition(upperBound >= lowerBound)
    precondition(graphemeLowerBound >= 0)
    precondition(graphemeUpperBound >= graphemeLowerBound)
    self.lowerBound = lowerBound
    self.upperBound = upperBound
    self.graphemeLowerBound = graphemeLowerBound
    self.graphemeUpperBound = graphemeUpperBound
  }

  public var isEmpty: Bool {
    lowerBound == upperBound
  }

  public var utf8Length: Int {
    upperBound - lowerBound
  }

  public func text(in source: String) -> Substring? {
    guard upperBound <= source.utf8.count else {
      return nil
    }

    let utf8 = source.utf8
    let lowerUTF8Index = utf8.index(utf8.startIndex, offsetBy: lowerBound)
    let upperUTF8Index = utf8.index(utf8.startIndex, offsetBy: upperBound)
    guard
      let lowerIndex = String.Index(lowerUTF8Index, within: source),
      let upperIndex = String.Index(upperUTF8Index, within: source)
    else {
      return nil
    }

    return source[lowerIndex..<upperIndex]
  }

  package func union(_ other: SourceRange) -> SourceRange {
    SourceRange(
      lowerBound: min(lowerBound, other.lowerBound),
      upperBound: max(upperBound, other.upperBound),
      graphemeLowerBound: min(graphemeLowerBound, other.graphemeLowerBound),
      graphemeUpperBound: max(graphemeUpperBound, other.graphemeUpperBound)
    )
  }
}
