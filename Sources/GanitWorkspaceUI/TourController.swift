import AppKit
import GanitEditorUI

/// A short first-run walkthrough. Skip or the last Next marks it done.
@MainActor
public final class TourController: NSViewController {
  public struct Step: Equatable {
    public let title: String
    public let body: String
  }

  public static let steps: [Step] = [
    Step(
      title: localized("tour.step1.title", "Write a line"),
      body: localized(
        "tour.step1.body",
        "Type a calculation and press Return for the next line. The answer appears beside it as you type."
      )
    ),
    Step(
      title: localized("tour.step2.title", "Name a value"),
      body: localized(
        "tour.step2.body",
        "rent = 2,100 names a number. A later line can write rent * 12, and changing rent updates every line that uses it."
      )
    ),
    Step(
      title: localized("tour.step3.title", "Quick Ganit"),
      body: localized(
        "tour.step3.body",
        "Window ▸ Quick Ganit Shortcut… chooses keys that open the same calculator over any app, without bringing Ganit’s windows forward."
      )
    ),
    Step(
      title: localized("tour.step4.title", "Help is searchable"),
      body: localized(
        "tour.step4.body",
        "Help ▸ Ganit Help searches the grammar and functions. Hover a name or an error for its signature or message. You can open this tour again from Settings or Help."
      )
    ),
  ]

  public private(set) var index = 0
  private let didFinish: () -> Void
  private let titleLabel = NSTextField(labelWithString: "")
  private let bodyLabel = NSTextField(wrappingLabelWithString: "")
  private let progress = NSTextField(labelWithString: "")
  private let nextButton = NSButton()

  public init(didFinish: @escaping () -> Void) {
    self.didFinish = didFinish
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  public override func loadView() {
    titleLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    bodyLabel.textColor = VisualStyle.Color.primary
    progress.textColor = VisualStyle.Color.secondary
    progress.font = VisualStyle.Typography.caption

    nextButton.bezelStyle = .push
    nextButton.keyEquivalent = "\r"
    nextButton.target = self
    nextButton.action = #selector(advance(_:))
    let skip = NSButton(
      title: localized("tour.skip", "Skip"), target: self, action: #selector(skip(_:)))
    skip.keyEquivalent = "\u{1b}"
    let buttons = NSStackView(views: [skip, nextButton])
    buttons.spacing = VisualStyle.Spacing.related

    let stack = NSStackView(views: [progress, titleLabel, bodyLabel, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = VisualStyle.Spacing.group
    let margin = VisualStyle.Spacing.window
    stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      bodyLabel.widthAnchor.constraint(equalToConstant: 380),
    ])
    view = container
    showStep()
  }

  @objc func advance(_ sender: Any?) {
    if index + 1 >= Self.steps.count {
      finish()
      return
    }
    index += 1
    showStep()
  }

  @objc func skip(_ sender: Any?) {
    finish()
  }

  private func finish() {
    didFinish()
    if let window = view.window {
      window.sheetParent?.endSheet(window)
      window.close()
    }
  }

  private func showStep() {
    let step = Self.steps[index]
    titleLabel.stringValue = step.title
    bodyLabel.stringValue = step.body
    progress.stringValue = String(
      format: localized("tour.progress", "Step %d of %d"),
      index + 1, Self.steps.count
    )
    nextButton.title =
      index + 1 >= Self.steps.count
      ? localized("tour.done", "Done")
      : localized("tour.next", "Next")
  }
}
