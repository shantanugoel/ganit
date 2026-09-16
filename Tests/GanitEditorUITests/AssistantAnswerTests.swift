import AppKit
import Foundation
import GanitEngine
import Testing

@testable import GanitEditorUI

/// A line Ganit cannot work out can be passed to an assistant, whose answer
/// arrives later and is written in a colour of its own.
@MainActor
@Suite
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

    textView.askAssistant(nil)
    let cells = try await answers(of: textView) { $0.first?.text.contains("5") == true }
    #expect(cells.first?.isFailure == false)
    #expect(await asked.recorded == ["10 kg of water in ml", "10 kg of water in ml"])
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
  }

  /// Collects the lines an assistant was asked about.
  private actor Asked {
    private(set) var recorded: [String] = []

    func record(_ line: String) {
      recorded.append(line)
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
    Self.windows.append(window)
    return editor
  }
}
