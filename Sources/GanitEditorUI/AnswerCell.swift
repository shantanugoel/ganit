import AppKit

/// What the answer column shows for one line: a formatted result or a
/// failure's message, with the details its interpretation card lists.
struct AnswerCell: Equatable {
  struct Detail: Equatable {
    let label: String
    let value: String
  }

  let text: String
  /// The exact value for Copy Full Precision; `nil` for failures.
  let fullPrecision: String?
  let details: [Detail]

  var isFailure: Bool {
    fullPrecision == nil
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
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        let value = NSTextField(labelWithString: detail.value)
        value.isSelectable = true
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return [label, value]
      }
    )
    grid.rowSpacing = 6
    grid.columnSpacing = 12
    grid.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
      grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
      grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
    ])
    view = container
  }
}
