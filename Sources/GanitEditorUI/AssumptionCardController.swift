import AppKit

@MainActor
final class AssumptionCardController: NSViewController {
  private let details: [(String, String)]
  private let copiedSource: String
  private let change: () -> Void
  private let preview: () async throws -> String
  private let remove: () throws -> Void
  private let stack = NSStackView()
  private let review = NSTextField(wrappingLabelWithString: "")
  private var removeButton: NSButton!
  private var reviewed = false

  init(
    details: [(String, String)], copiedSource: String, change: @escaping () -> Void,
    preview: @escaping () async throws -> String, remove: @escaping () throws -> Void
  ) {
    self.details = details
    self.copiedSource = copiedSource
    self.change = change
    self.preview = preview
    self.remove = remove
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func loadView() {
    stack.setAccessibilityElement(true)
    stack.setAccessibilityRole(.group)
    stack.setAccessibilityLabel(localized("assumption.panel", "AI assumption"))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    for (name, value) in details {
      let field = NSTextField(wrappingLabelWithString: name + ": " + value)
      field.preferredMaxLayoutWidth = 440
      field.isSelectable = true
      field.setAccessibilityLabel(name)
      stack.addArrangedSubview(field)
    }
    review.preferredMaxLayoutWidth = 440
    review.isSelectable = true
    review.isHidden = true
    stack.addArrangedSubview(review)
    let actions = NSStackView()
    actions.orientation = .horizontal
    actions.spacing = 8
    actions.addArrangedSubview(
      NSButton(
        title: localized("assumption.changeValue", "Change value…"), target: self,
        action: #selector(changeValue)))
    removeButton = NSButton(
      title: localized("assumption.remove", "Remove"), target: self,
      action: #selector(reviewRemoval))
    actions.addArrangedSubview(removeButton)
    actions.addArrangedSubview(
      NSButton(
        title: localized("assumption.copy", "Copy"), target: self, action: #selector(copySource)))
    stack.addArrangedSubview(actions)
    view = stack
    resize()
  }

  private func resize() {
    let size = NSSize(width: 472, height: max(180, stack.fittingSize.height))
    preferredContentSize = size
    view.frame.size = size
  }

  @objc private func changeValue() { change() }
  @objc private func copySource() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(copiedSource, forType: .string)
  }
  @objc private func reviewRemoval() {
    if reviewed {
      do { try remove() } catch {
        review.stringValue = localized(
          "assumption.changed", "The sheet changed. Open this assumption again.")
        reviewed = false
        removeButton.isEnabled = false
      }
      return
    }
    removeButton.isEnabled = false
    Task { [weak self] in
      guard let self else { return }
      do {
        review.stringValue = try await preview()
        review.isHidden = false
        reviewed = true
        removeButton.title = localized("assumption.confirmRemoval", "Remove value")
        removeButton.isEnabled = true
      } catch {
        review.stringValue = localized(
          "assumption.changed", "The sheet changed. Open this assumption again.")
        review.isHidden = false
      }
      resize()
    }
  }
}
