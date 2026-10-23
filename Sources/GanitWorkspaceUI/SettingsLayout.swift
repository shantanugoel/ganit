import AppKit
import GanitEditorUI

/// The form grammar the Settings window uses. Both tabs are built from these
/// pieces, so the widths, the label column, the groups, and the supporting
/// text all read the same way.
///
/// A person reads a settings panel by scanning the names, not the controls,
/// so every name sits in one trailing-aligned column and every control starts
/// at the same edge. Related controls sit inside a titled group, which lets
/// the eye stop between decisions instead of at every row.
enum SettingsLayout {
  /// The width every panel keeps, so explanation, groups, and status lines all
  /// end at the same edge.
  static let contentWidth: CGFloat = 460
  /// The gap between a group's border and what it holds.
  static let sectionInset: CGFloat = VisualStyle.Spacing.group
  /// The width left for controls once a group's border and insets are gone.
  static var controlAreaWidth: CGFloat { contentWidth - 2 * sectionInset }
  /// The width of the trailing-aligned name column beside a control.
  static let labelColumnWidth: CGFloat = 128
  /// The width of a text field that fills the rest of a row.
  static var fieldWidth: CGFloat {
    controlAreaWidth - labelColumnWidth - VisualStyle.Spacing.group
  }

  /// Supporting text: smaller and dimmer than a field, so a panel reads as its
  /// controls first and its explanation second.
  static func caption(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.textColor = VisualStyle.Color.secondary
    field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    return field
  }

  /// The name of a control, in the column every name shares.
  static func name(_ text: String) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.textColor = VisualStyle.Color.secondary
    return field
  }

  /// Rows of a form: each name in the trailing-aligned column, its control
  /// beside it at the shared edge.
  static func rows(_ rows: [(String, NSView)]) -> NSGridView {
    let grid = NSGridView(views: rows.map { [name($0.0), $0.1] })
    grid.yPlacement = .center
    grid.rowSpacing = VisualStyle.Spacing.related
    grid.columnSpacing = VisualStyle.Spacing.group
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 0).width = labelColumnWidth
    // Spare height belongs to the explanation, not between rows.
    grid.setContentHuggingPriority(.defaultHigh, for: .vertical)
    return grid
  }

  /// Stacked views that share the full width of a panel or a group.
  static func stack(_ views: [NSView], spacing: CGFloat = VisualStyle.Spacing.related)
    -> NSStackView
  {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
  }

  /// A named group. The name sits on the border, so a long form reads as a few
  /// decisions instead of one unbroken list.
  static func section(_ title: String, _ content: NSView) -> NSBox {
    let box = NSBox()
    box.boxType = .primary
    box.titlePosition = .atTop
    box.title = title
    box.titleFont = NSFont.preferredFont(forTextStyle: .subheadline)
    box.cornerRadius = 6
    box.contentViewMargins = .zero
    box.translatesAutoresizingMaskIntoConstraints = false
    box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    guard let host = box.contentView else { return box }
    content.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: sectionInset),
      content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -sectionInset),
      content.topAnchor.constraint(equalTo: host.topAnchor, constant: sectionInset),
      content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -sectionInset),
    ])
    return box
  }

  /// The panel itself: the views, one width apart from the window edge, with
  /// the group's trailing edge kept free for a default button.
  static func panel(_ views: [NSView], height: CGFloat) -> NSView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = VisualStyle.Spacing.group
    let margin = VisualStyle.Spacing.window
    stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(
      frame: NSRect(x: 0, y: 0, width: contentWidth + 2 * margin, height: height))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  /// Actions along the bottom of a panel: the first keeps the leading edge and
  /// the last, which is the default button, sits where a person looks for it.
  static func actions(_ leading: NSView..., trailing: NSView) -> NSStackView {
    let spacer = NSView()
    spacer.setContentHuggingPriority(.init(1), for: .horizontal)
    let bar = NSStackView(views: leading + [spacer, trailing])
    bar.orientation = .horizontal
    bar.spacing = VisualStyle.Spacing.group
    bar.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
    return bar
  }

  /// Pin a wrapping line of text to the panel width so it wraps instead of
  /// running past the edge.
  static func bindWidth(_ field: NSTextField) -> NSLayoutConstraint {
    field.widthAnchor.constraint(equalToConstant: contentWidth)
  }
}
