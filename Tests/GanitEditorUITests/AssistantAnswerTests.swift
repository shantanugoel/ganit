import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

/// A line Ganit cannot work out can be passed to an assistant, whose answer
/// arrives later and is written in a colour of its own.
@MainActor
@Suite(.serialized)
struct AssistantAnswerTests {
  @Test
  func theAssistantAnswersTheLineGanitCouldNot() async throws {
    let asked = Asked()
    let editor = try makeEditor("2 + 2\n10 kg of water in ml")
    editor.askAssistant = { line in
      await asked.record(line)
      return "10,000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    let answers = try await answers(of: textView) { $0.count == 2 && $0[1].isAssisted }

    // Only the line Ganit could not work out is asked about, and only its
    // text is.
    #expect(await asked.recorded == ["10 kg of water in ml"])
    #expect(answers.map(\.text) == ["4", "10,000 ml"])
    // The assistant's answer is not a failure, and not Ganit's arithmetic
    // either, so it is written as neither.
    #expect(!answers[1].isFailure)
    #expect(answers[1].fullPrecision == nil)
    let exported = await editor.exportedLines()
    #expect(exported.map(\.status) == [.calculated, .aiUnverified])
    #expect(SheetDocumentRenderer.csv(exported).contains("ai-unverified"))
    #expect(
      textView.linesWithResults(
        in: NSRange(
          location: 0, length: textView.string.utf16.count)
      ).contains("10,000 ml [AI; unverified]"))
  }

  /// An assistant's answer carries a textual AI badge, for readers, hover,
  /// and VoiceOver, rather than relying on its colour.
  @Test
  func anAssistedAnswerIsLabelledAI() async throws {
    let editor = try makeEditor("10 kg of water in ml")
    editor.askAssistant = { _ in "10,000 ml" }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.first?.isAssisted == true }

    let answer = try #require(textView.answerLayout(in: textView.bounds).first)
    let textWidth = ceil(
      ("10,000 ml" as NSString).size(
        withAttributes: textView.attributes(for: answer.cell, selected: false)
      ).width)
    #expect(textView.badgeWidth(for: answer.cell) > 0)
    #expect(answer.rect.width == textWidth + textView.badgeWidth(for: answer.cell))
    #expect(
      textView.tooltip(at: NSPoint(x: answer.rect.midX, y: answer.rect.midY))
        == "10,000 ml — AI answer, unverified. Formulas cannot use it.")
    let element = try #require(
      textView.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement }
        .first { $0.accessibilityValue() as? String == "10,000 ml" })
    #expect(element.accessibilityLabel() == "Line 1 AI answer, unverified")
    #expect(textView.badgeWidth(for: AnswerCell(text: "4", fullPrecision: "4")) == 0)
  }

  /// A line written with the other decimal separator is corrected, not sent
  /// to the assistant.
  @Test
  func mismatchedSeparatorsAreExplainedInsteadOfAsked() async throws {
    let asked = Asked()
    let editor = try makeEditor("1,5 + 2,5\nx = 1.234,56 + 1 // total")
    editor.askAssistant = { line in
      await asked.record(line)
      return "4"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    try await Task.sleep(for: .milliseconds(100))

    #expect(await asked.recorded.isEmpty)
    let exported = await editor.exportedLines()
    #expect(exported.allSatisfy { $0.answer?.contains("Decimal Comma") == true })
    let suggestion = { (index: Int) in
      textView.interpretation(editor.sheet.lines[index].id).first { $0.label == "Suggestion" }?
        .value
    }
    #expect(suggestion(0) == "1.5 + 2.5")
    #expect(suggestion(1) == "1,234.56 + 1")
  }

  @Test
  func knownUnitAndRateErrorsAreNotSentToTheAssistant() async throws {
    let asked = Asked()
    let editor = try makeEditor("INR7.23 + 1.15\n$1.1m to INR")
    editor.askAssistant = { line in
      await asked.record(line)
      return "999999"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await asked.recorded.isEmpty)
    let exported = await editor.exportedLines()
    #expect(exported[0].answer?.contains("Unit mismatch") == true)
    #expect(exported[1].answer?.contains("Exchange rates") == true)
  }

  @Test
  func askAssistantReturnsAValueLaterLinesCanUse() async throws {
    let asked = Asked()
    let editor = try makeEditor("ask_assistant(10 kg of water in ml)\nprevious * 2")
    editor.askAssistant = { line in
      await asked.record(line)
      return "10000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    let answers = try await answers(of: textView) { $0.count == 2 && !$0[1].isFailure }

    #expect(await asked.recorded == ["10 kg of water in ml"])
    #expect(answers[0].text.contains("mL"))
    #expect(answers[1].text.contains("mL"))
    #expect(!answers[0].isFailure)
    #expect(!answers[1].isFailure)
  }

  /// A placeholder's value is written into the prompt as the sheet shows it.
  @Test
  func askAssistantSendsPlaceholderValues() async throws {
    let asked = Asked()
    let editor = try makeEditor("weight = 1200 kg\nask_assistant({weight} of water in ml)")
    editor.askAssistant = { line in
      await asked.record(line)
      return "1200000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    let answers = try await answers(of: textView) { $0.count == 2 && !$0[1].isFailure }

    #expect(await asked.recorded == ["1,200 kg of water in ml"])
    #expect(answers[1].text.contains("mL"))
  }

  /// Without an assistant a line Ganit cannot work out keeps saying so, and
  /// nothing is asked of anyone.
  @Test
  func saysWhatIsWrongWhenThereIsNoAssistant() async throws {
    let editor = try makeEditor("10 kg of water in ml")
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()

    let answer = try #require(textView.answerLayout(in: textView.bounds).first?.cell)
    #expect(answer.isFailure)
    #expect(!answer.isAssisted)
  }

  /// The assistant is asked once for a line, however often the sheet is
  /// worked out again.
  @Test
  func asksOnceForALine() async throws {
    let asked = Asked()
    let editor = try makeEditor("10 kg of water in ml")
    editor.askAssistant = { line in
      await asked.record(line)
      return "10,000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.first?.isAssisted == true }

    for _ in 0..<3 {
      editor.recalculate(nil)
      await editor.scheduler?.waitUntilIdle()
    }
    try await Task.sleep(for: .milliseconds(100))

    #expect(await asked.recorded == ["10 kg of water in ml"])
  }

  @Test
  func askAssistantAsksAFailedLineAgain() async throws {
    let asked = Asked()
    let editor = try makeEditor("10 kg of water in ml")
    editor.askAssistant = { line in
      await asked.record(line)
      return await asked.recorded.count == 1 ? "10,000 ml" : "9,000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.first?.isAssisted == true }

    let item = NSMenuItem(
      title: "", action: #selector(SheetCommands.askAssistant(_:)), keyEquivalent: "")
    #expect(textView.validateUserInterfaceItem(item))
    textView.askAssistant(nil)
    let cells = try await answers(of: textView) { $0.first?.text == "9,000 ml" }
    #expect(cells.first?.isAssisted == true)
    #expect(await asked.recorded == ["10 kg of water in ml", "10 kg of water in ml"])
  }

  @Test
  func askAssistantAsksAPromptAgain() async throws {
    let asked = Asked()
    let editor = try makeEditor("ask_assistant(10 kg of water in ml)")
    editor.askAssistant = { line in
      await asked.record(line)
      return await asked.recorded.count == 1 ? "10000 ml" : "5000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.first?.isFailure == false }

    var forgotten: [String] = []
    editor.forgetAssistantAnswer = { forgotten.append($0) }
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.askAssistant(nil)
    let cells = try await answers(of: textView) { $0.first?.text.contains("5") == true }
    #expect(cells.first?.isFailure == false)
    #expect(await asked.recorded == ["10 kg of water in ml", "10 kg of water in ml"])
    // A kept reply is forgotten, so the model is asked rather than repeated.
    #expect(forgotten == ["10 kg of water in ml"])
  }

  @Test
  func showsAskingUntilTheAssistantAnswers() async throws {
    let gate = Gate()
    let editor = try makeEditor("10 kg of water in ml")
    editor.askAssistant = { _ in
      await gate.wait()
      return "10,000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    let pending = try await answers(of: textView) { $0.first?.isPending == true }
    #expect(pending.first?.text == "Asking…")
    #expect(pending.first?.isFailure == false)
    await gate.open()
    let done = try await answers(of: textView) { $0.first?.isAssisted == true }
    #expect(done.first?.text == "10,000 ml")
  }

  /// Stop cancels assistant requests as well as evaluation, and a cancelled
  /// line is not asked about again until Ask Assistant.
  @Test
  func stopCancelsAssistantRequests() async throws {
    let asked = Asked()
    let editor = try makeEditor("10 kg of water in ml\nask_assistant(5 kg of water in ml)")
    editor.askAssistant = { line in
      await asked.record(line)
      try? await Task.sleep(for: .seconds(30))
      if Task.isCancelled {
        await asked.record("cancelled")
      }
      return "10000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.count == 2 && $0.allSatisfy(\.isPending) }

    editor.stopCalculation(nil)
    let stopped = try await answers(of: textView) {
      $0.count == 2 && !$0.contains(where: \.isPending)
    }
    #expect(stopped.allSatisfy { $0.isFailure && !$0.isAssisted })
    for _ in 0..<50 where await asked.recorded.count < 4 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await asked.recorded.filter { $0 == "cancelled" }.count == 2)

    // Moving about and recalculating do not send them again.
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    editor.recalculate(nil)
    await editor.scheduler?.waitUntilIdle()
    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    try await Task.sleep(for: .milliseconds(100))
    #expect(await asked.recorded.count == 4)
    #expect(textView.answerLayout(in: textView.bounds).allSatisfy { !$0.cell.isPending })

    // Ask Assistant asks again.
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.askAssistant(nil)
    _ = try await answers(of: textView) { $0.first?.isPending == true }
    for _ in 0..<50 where await asked.recorded.count < 5 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await asked.recorded.count == 5)
    editor.stopCalculation(nil)
  }

  /// Cancel Request stops waiting for one line, and a late reply is ignored.
  @Test
  func cancelRequestCancelsOnlyTheSelectedLine() async throws {
    let gate = Gate()
    let editor = try makeEditor("10 kg of water in ml\n5 kg of water in ml")
    editor.askAssistant = { line in
      await gate.wait()
      return line.hasPrefix("10") ? "10,000 ml" : "5,000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.count == 2 && $0.allSatisfy(\.isPending) }

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let item = NSMenuItem(
      title: "", action: #selector(SheetCommands.cancelAssistantRequest(_:)), keyEquivalent: "")
    #expect(textView.validateUserInterfaceItem(item))
    textView.cancelAssistantRequest(nil)
    #expect(!textView.validateUserInterfaceItem(item))
    await gate.open()
    let cells = try await answers(of: textView) { $0.count == 2 && $0[1].isAssisted }
    #expect(cells[0].isFailure)
    #expect(!cells[0].isAssisted)
    #expect(cells[1].text == "5,000 ml")
  }

  /// A temporary correction made while a request is pending is not replaced
  /// by that request's late reply.
  @Test
  func aCorrectionIsNotReplacedByALateReply() async throws {
    let gate = Gate()
    let editor = try makeEditor("10 kg of water in ml")
    editor.askAssistant = { _ in
      await gate.wait()
      return "10,000 ml"
    }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.first?.isPending == true }
    editor.applyAssistantAnswer("9,000 ml")
    await gate.open()
    try await Task.sleep(for: .milliseconds(100))
    let cells = try await answers(of: textView) { $0.first?.text == "9,000 ml" }
    #expect(cells.first?.isAssisted == true)
  }

  /// A line referring to an AI display answer says why it cannot use it, and
  /// the answer's card says how to make it a value.
  @Test
  func referencesToAnAIDisplayAnswerExplainThemselves() async throws {
    let editor = try makeEditor("10 kg of water in ml\nline 1 * 2\n1/0\nprevious + 1")
    editor.askAssistant = { line in line.hasPrefix("10") ? "10,000 ml" : nil }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    let cells = try await answers(of: textView) {
      $0.count == 4 && $0[0].isAssisted && $0[1].text.contains("AI")
    }
    #expect(cells[1].isFailure)
    #expect(cells[1].text.hasPrefix("Line 1 has an AI display answer"))
    // An ordinary failure is still described as one.
    #expect(!cells[3].text.contains("AI"))

    let card = textView.interpretation(editor.sheet.lines[0].id)
    #expect(card.contains { $0.label == "AI answer" && $0.value == "10,000 ml" })
    #expect(card.contains { $0.value.contains("Formulas cannot refer to it") })

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(editor.saveAssistantAnswerAsValue("10000 ml"))
    let exported = await editor.exportedLines()
    #expect(exported.map(\.status) == [.calculated, .calculated, .failure, .failure])
  }

  @Test
  func aChangedAssistantAnswerReplacesThePurpleValue() async throws {
    let editor = try makeEditor("10 kg of water in ml")
    editor.askAssistant = { _ in "10,000 ml" }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.first?.isAssisted == true }

    let item = NSMenuItem(
      title: "", action: #selector(SheetCommands.changeAssistantAnswer(_:)), keyEquivalent: "")
    #expect(textView.validateUserInterfaceItem(item))
    editor.applyAssistantAnswer("9,000 ml")
    let cells = try await answers(of: textView) { $0.first?.text == "9,000 ml" }
    #expect(cells.first?.isAssisted == true)
  }

  @Test
  func savedManualCorrectionsReopenWithoutAnAssistant() async throws {
    let source = "10 kg of water in ml\nprevious * 2"
    let editor = try makeEditor(source)
    editor.askAssistant = { _ in "10,000 ml" }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.first?.isAssisted == true }
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(editor.saveAssistantAnswerAsValue("12345 ml"))
    let saved = editor.sheet.text
    #expect(saved.hasPrefix("12345 ml // Manual answer; original: 10 kg of water in ml"))
    let reopened = try makeEditor(saved)
    let exported = await reopened.exportedLines()
    #expect(exported.map(\.status) == [.calculated, .calculated])
    #expect(exported[0].answer?.contains("12,345") == true)
    #expect(exported[1].answer?.contains("24,690") == true)
    editor.documentUndoManager.undo()
    #expect(editor.sheet.text == source)
    editor.documentUndoManager.redo()
    #expect(editor.sheet.text == saved)
  }

  @Test
  func savingRejectsInvalidOrAssistedValuesWithoutEditingSource() async throws {
    let source = "10 kg of water in ml"
    let editor = try makeEditor(source)
    await editor.scheduler?.waitUntilIdle()
    for value in ["", "not a value", "1/0", "1\n2", "ask_assistant(water)"] {
      #expect(!editor.saveAssistantAnswerAsValue(value))
      #expect(editor.sheet.text == source)
    }
  }

  @Test
  func aChangedAssistantPromptIsWhatLaterLinesUse() async throws {
    let editor = try makeEditor("ask_assistant(10 kg of water in ml)\nprevious * 2")
    editor.askAssistant = { _ in "10000 ml" }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    _ = try await answers(of: textView) { $0.count == 2 && !$0[1].isFailure }

    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(editor.canChangeAssistantAnswer())
    editor.applyAssistantAnswer("5000 ml")
    await editor.scheduler?.waitUntilIdle()
    let cells = textView.answerLayout(in: textView.bounds).map(\.cell)
    #expect(cells.map(\.text) == ["5,000 mL", "10,000 mL"])
  }

  @Test
  func askAssistantStaysOffForAWorkedOutLine() async throws {
    let editor = try makeEditor("2 + 2")
    editor.askAssistant = { _ in "no" }
    let textView = try #require(editor.textView as? SheetTextView)
    await editor.scheduler?.waitUntilIdle()
    let item = NSMenuItem(
      title: "", action: #selector(SheetCommands.askAssistant(_:)), keyEquivalent: "")
    #expect(!textView.validateUserInterfaceItem(item))
    let change = NSMenuItem(
      title: "", action: #selector(SheetCommands.changeAssistantAnswer(_:)), keyEquivalent: "")
    #expect(!textView.validateUserInterfaceItem(change))
  }

  /// Collects the lines an assistant was asked about.
  private actor Asked {
    private(set) var recorded: [String] = []

    func record(_ line: String) {
      recorded.append(line)
    }
  }

  /// Holds an assistant reply until the test has seen Asking….
  private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if isOpen {
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      isOpen = true
      for waiter in waiters {
        waiter.resume()
      }
      waiters = []
    }
  }

  /// The answers on screen once they are what the test is waiting for, since
  /// an assistant answers a line after Ganit has already written its own.
  private func answers(
    of textView: SheetTextView,
    until settled: ([AnswerCell]) -> Bool
  ) async throws -> [AnswerCell] {
    for _ in 0..<200 {
      let answers = textView.answerLayout(in: textView.bounds).map(\.cell)
      if settled(answers) {
        return answers
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The answers never settled.")
    return textView.answerLayout(in: textView.bounds).map(\.cell)
  }

  private static var windows: [NSWindow] = []

  private func makeEditor(_ text: String) throws -> SheetEditorViewController {
    let editor = SheetEditorViewController(
      text: text,
      context: try EvaluationContext(
        localeIdentifier: "en-US",
        lexingConfiguration: .englishUnitedStates,
        angleMode: .radians,
        precision: PrecisionContext(significantDecimalDigits: 15),
        now: Date(timeIntervalSince1970: 0),
        calendar: Calendar(identifier: .gregorian),
        timeZone: try #require(TimeZone(identifier: "UTC"))
      )
    )
    // Tests do not type, so they need not wait for typing to stop.
    editor.assistantPause = .zero
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    window.contentViewController = editor
    window.layoutIfNeeded()
    window.makeFirstResponder(editor.textView)
    Self.windows.append(window)
    return editor
  }
}
