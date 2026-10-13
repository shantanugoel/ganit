import Foundation
import Testing

@testable import GanitEngine

@Suite
struct AssistanceSnapshotTests {
  @Test func usesNativeScopeAndDoesNotSendUnselectedSource() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource(
      "# Dinner\nsecret = 9876\nbill = 2400 INR\n// Tip applies to bill.\nAdd a 10% tip to bill, then split it four ways."
    )
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[4].id)
    #expect(snapshot.evaluation.generation == calculator.generation)
    #expect(snapshot.inventory.map(\.name) == ["bill", "secret"])
    #expect(snapshot.inventory[0].declaration?.id == sheet.lines[2].id)
    #expect(snapshot.notes.map(\.source) == ["# Dinner", "// Tip applies to bill."])
    let data = try snapshot.permittedContext()
    #expect(data == (try snapshot.permittedContext()))
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("2400"))
    #expect(!text.contains("secret"))
    #expect(!text.contains("9876"))
    #expect(!text.contains("assistantAnswers"))
    #expect(snapshot.source.text == sheet.text)
  }

  @Test func capturesRedeclarationsDividersAndFrozenValues() throws {
    var calculator = SheetCalculator(
      definitions: SheetDefinitions(variables: ["base": .number(.integer(IntegerValue(7)))]))
    var sheet = SheetSource("bill = 100\nbill = 200\nAdd bill to base")
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[2].id)
    let bill = try #require(snapshot.inventory.first { $0.name == "bill" })
    #expect(bill.declaration?.id == sheet.lines[1].id)
    #expect(bill.value == .number(.integer(IntegerValue(200))))
    sheet.replace(
      utf8Range: sheet.lines[1].range.lowerBound..<sheet.lines[1].range.upperBound,
      with: "bill = 500")
    _ = try calculator.evaluate(sheet, context: sheetContext())
    #expect(bill.value == .number(.integer(IntegerValue(200))))
    #expect(snapshot.source.lines[1].text == "bill = 200")
    let divided = SheetSource("bill = 100\n---\nAdd bill to base")
    let afterDivider = try calculator.assistanceSnapshot(
      divided, context: sheetContext(), target: divided.lines[2].id)
    #expect(afterDivider.inventory.filter { $0.kind == "variable" }.map(\.name) == ["base"])
    #expect(afterDivider.inventory[0].declaration == nil)
  }

  @Test func reusesEvaluationAndPreservesFailedInputs() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("bill = 1 / 0\nAdd a tip to bill")
    _ = try calculator.evaluate(sheet, context: sheetContext())
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[1].id)
    #expect(snapshot.evaluation.evaluatedLineIDs.isEmpty)
    #expect(snapshot.inventory[0].value == nil)
    let root = try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext()) as? [String: Any])
    let symbols = try #require(root["symbols"] as? [[String: Any]])
    #expect(symbols[0]["unavailable"] as? Bool == true)
    #expect(symbols[0]["value"] == nil)
  }

  @Test func notesAreContiguousAndHistoryIsMarked() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource(
      "// Distant private note\n\n  // Request record: old bill of 100\nAdd a tip to bill")
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(isMarkdownMode: true), target: sheet.lines[3].id)
    #expect(snapshot.notes.count == 1)
    #expect(snapshot.notes[0].historical)
    #expect(
      !String(decoding: try snapshot.permittedContext(), as: UTF8.self).contains(
        "Distant private note"))
  }

  @Test func doesNotSilentlyCutOffALargeTarget() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource(String(repeating: "é", count: 4_097))
    #expect(throws: AssistanceSnapshotError.targetTooLarge) {
      try calculator.assistanceSnapshot(sheet, context: sheetContext(), target: sheet.lines[0].id)
    }
    #expect(calculator.generation == 0)
  }
  @Test func includesNativeDiagnosticCodesAndRanges() throws {
    var calculator = SheetCalculator()
    let sheet = SheetSource("1 / 0")
    let snapshot = try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines[0].id)
    let root = try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext()) as? [String: Any])
    let diagnostics = try #require(root["diagnostics"] as? [[String: Any]])
    #expect(diagnostics[0]["code"] as? String == "evaluation.divisionByZero")
    let spans = try #require(diagnostics[0]["spans"] as? [[String: Int]])
    #expect(spans[0]["utf8Start"] == 4)
    #expect(spans[0]["utf8End"] == 5)
  }

}
