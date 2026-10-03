import AppKit

/// Native Find searches canonical source and opens mapped table hits.
@MainActor
final class MappedTableFinder: NSTextFinder {
  private let sourceClient: MappedTableFindClient
  private weak var textView: SheetTextView?
  init(textView: SheetTextView) {
    self.textView = textView
    sourceClient = MappedTableFindClient(textView: textView)
    super.init()
    client = sourceClient
    isIncrementalSearchingEnabled = true
    incrementalSearchingShouldDimContentView = false
  }
  @available(*, unavailable)
  required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func performAction(_ action: NSTextFinder.Action) {
    textView?.isPerformingFind = true
    defer { textView?.isPerformingFind = false }
    super.performAction(action)
    if action == .nextMatch || action == .previousMatch { textView?.findTableHit() }
  }
}

/// A find client that searches the canonical sheet source. Find results keep
/// source offsets, so Find can open the mapped table cell for a hit.
@MainActor
final class MappedTableFindClient: NSObject, @preconcurrency NSTextFinderClient {
  private unowned let textView: SheetTextView
  init(textView: SheetTextView) { self.textView = textView }
  var string: String { textView.string }
  var isSelectable: Bool { textView.isSelectable }
  var isEditable: Bool { textView.isEditable }
  var allowsMultipleSelection: Bool { true }
  var firstSelectedRange: NSRange { textView.selectedRange() }
  var selectedRanges: [NSValue] {
    get { textView.selectedRanges }
    set { textView.selectedRanges = newValue }
  }
  func scrollRangeToVisible(_ range: NSRange) {
    // The finder reports each match here. A match must also become the
    // selection so Find can open the mapped table cell for it.
    if range.length > 0 { textView.setSelectedRange(range) }
    textView.scrollRangeToVisible(range)
    // Find-bar buttons call the client directly. Wait for its selection update.
    DispatchQueue.main.async { [weak textView] in textView?.findTableHit() }
  }
  func shouldReplaceCharacters(inRanges ranges: [NSValue], with strings: [String]) -> Bool {
    textView.shouldChangeText(inRanges: ranges, replacementStrings: strings)
  }
  func replaceCharacters(in range: NSRange, with string: String) {
    textView.textStorage?.replaceCharacters(in: range, with: string)
  }
  func didReplaceCharacters() { textView.didChangeText() }
  func contentView(at index: Int, effectiveCharacterRange range: NSRangePointer) -> NSView {
    range.pointee = NSRange(location: 0, length: string.utf16.count)
    return textView
  }
  func rects(forCharacterRange range: NSRange) -> [NSValue]? {
    guard let manager = textView.textLayoutManager, let content = manager.textContentManager,
      let start = content.location(content.documentRange.location, offsetBy: range.location),
      let end = content.location(start, offsetBy: range.length),
      let textRange = NSTextRange(location: start, end: end)
    else { return nil }
    var rectangles: [NSValue] = []
    manager.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) {
      _, rect, _, _ in
      rectangles.append(
        NSValue(
          rect: rect.offsetBy(
            dx: self.textView.textContainerOrigin.x, dy: self.textView.textContainerOrigin.y)))
      return true
    }
    return rectangles
  }
  var visibleCharacterRanges: [NSValue] {
    [NSValue(range: NSRange(location: 0, length: string.utf16.count))]
  }
}
