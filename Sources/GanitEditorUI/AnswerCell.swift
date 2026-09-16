import AppKit

/// What the answer column shows for one line: a formatted result or a
/// failure's message.
struct AnswerCell: Equatable {
  /// A row of an answer's interpretation card.
  struct Detail: Equatable {
    let label: String
    let value: String
  }

  let text: String
  /// The exact value for Copy Full Precision; `nil` for failures.
  let fullPrecision: String?
  /// An answer from the assistant, which Ganit did not work out itself and so
  /// writes in a colour of its own.
  var isAssisted = false
  /// A request is in flight; the sheet stays editable.
  var isPending = false

  var isFailure: Bool {
    fullPrecision == nil && !isAssisted && !isPending
  }
}

/// Lists an answer's interpretation details as selectable label/value rows.
@MainActor
final class InterpretationViewController: NSViewController {
  private let details: [AnswerCell.Detail]

  init(details: [AnswerCell.Detail]) {
    self.details = details
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  override func loadView() {
    let grid = NSGridView(
      views: details.map { detail in
        let label = NSTextField(labelWithString: detail.label)
        label.textColor = VisualStyle.Color.secondary
        label.alignment = .right
        let value = NSTextField(labelWithString: detail.value)
        value.isSelectable = true
        value.font = VisualStyle.Typography.detailValue
        return [label, value]
      }
    )
    grid.rowSpacing = VisualStyle.Spacing.related
    grid.columnSpacing = VisualStyle.Spacing.group
    grid.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(
        equalTo: container.leadingAnchor, constant: VisualStyle.Spacing.card),
      grid.trailingAnchor.constraint(
        equalTo: container.trailingAnchor, constant: -VisualStyle.Spacing.card),
      grid.topAnchor.constraint(equalTo: container.topAnchor, constant: VisualStyle.Spacing.group),
      grid.bottomAnchor.constraint(
        equalTo: container.bottomAnchor, constant: -VisualStyle.Spacing.group),
    ])
    view = container
  }
}
