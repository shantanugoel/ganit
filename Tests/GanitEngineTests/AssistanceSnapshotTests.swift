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

  @Test func explicitTaskNotesSelectNativeNamesAndReferencesBeforeReview() throws {
    var calculator = SheetCalculator()
    let source = SheetSource("hidden = 10\n20\nf(x) = x * 3\nUse the amount above.")
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines[3].id)
    #expect(!String(decoding: try snapshot.permittedContext(), as: UTF8.self).contains("hidden"))
    let named = try snapshot.addingTaskNote("Use hidden with f.")
    #expect(named.inventory.first { $0.name == "hidden" }?.matchesTarget == true)
    #expect(
      named.inventory.first { $0.kind == "function" && $0.name == "f" }?.matchesTarget == true)
    let referenced = try snapshot.addingTaskNote("Use the amount on line 2.")
    #expect(referenced.inventory.first { $0.name == "@2" }?.matchesTarget == true)
    #expect(!referenced.evidence().contains { $0.kind == "literal" && $0.text == "2" })
    #expect(referenced.evidence().contains { $0.kind == "literal" && $0.text == "20" })
    #expect(snapshot.inventory.allSatisfy { !$0.matchesTarget })
  }

  @Test func wireHandlesDoNotExposeLocalLineOrDocumentIdentities() throws {
    let text = "base = 7\n14\nf(x) = x * base\nUse f with line 2."
    let original = SheetSource(text)
    var edited = SheetSource("temporary\n")
    edited.replace(utf8Range: 0..<edited.text.utf8.count, with: "")
    edited.replace(utf8Range: 0..<edited.text.utf8.count, with: text)
    #expect(original.lines.map(\.id) != edited.lines.map(\.id))
    var firstCalculator = SheetCalculator()
    var secondCalculator = SheetCalculator()
    let first = try firstCalculator.assistanceSnapshot(
      original, context: sheetContext(), target: original.lines.last!.id
    ).addingTaskNote("Use the amount on line 2.")
    let second = try secondCalculator.assistanceSnapshot(
      edited, context: sheetContext(), target: edited.lines.last!.id
    ).addingTaskNote("Use the amount on line 2.")
    let firstBody = try first.permittedContext()
    #expect(firstBody == (try second.permittedContext()))
    let root = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
    let symbols = try #require(root["symbols"] as? [[String: Any]])
    let result = try #require(symbols.first { $0["kind"] as? String == "line_result" })
    #expect(result["handle"] as? String == "R1")
    let wire = String(decoding: firstBody, as: UTF8.self)
    #expect(!wire.contains("line:"))
    #expect(!wire.contains(original.assistanceIdentity.uuidString))
    #expect(!wire.contains(edited.assistanceIdentity.uuidString))
    let function = try #require(symbols.first { $0["kind"] as? String == "function" })
    let context = try #require(function["function"] as? [String: Any])
    let definitions = try #require(context["definitions"] as? [[String: Any]])
    #expect(function["origin"] as? String == definitions[0]["origin"] as? String)
  }

  @Test func contextIncludesTransitiveScalarSourcesAtTheirOriginalDeclarations() throws {
    let source = SheetSource(
      "private = 987654\nfactor = 10\nsubtotal = factor * 2\nfactor = 99\ngrand_total = subtotal + 3\nUse grand_total with two."
    )
    var calculator = SheetCalculator()
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines.last!.id)
    let root = try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext()) as? [String: Any])
    #expect(
      snapshot.inventory.first { $0.name == "grand_total" }?.value
        == .number(.integer(IntegerValue(23))))
    let dependencies = try #require(root["dependencySources"] as? [[String: String]])
    #expect(
      Set(dependencies.compactMap { $0["source"] }) == ["subtotal = factor * 2", "factor = 10"])
    #expect(dependencies.allSatisfy { $0["origin"]?.hasPrefix("source:") == true })
    let body = String(decoding: try snapshot.permittedContext(), as: UTF8.self)
    #expect(!body.contains("factor = 99"))
    #expect(!body.contains("987654"))
  }

  @Test func taskNotesAndFunctionCapturesIncludeTheirTransitiveScalarSources() throws {
    let source = SheetSource(
      "factor = 10\nsubtotal = factor * 2\nf(x) = x * subtotal\nfactor = 99\nUse the value.")
    var calculator = SheetCalculator()
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines.last!.id)
    let empty = try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext()) as? [String: Any])
    #expect((empty["dependencySources"] as? [[String: String]])?.isEmpty == true)
    let revised = try snapshot.addingTaskNote("Use f with two.")
    let function = try #require(revised.inventory.first { $0.name == "f" }?.function)
    #expect(function.assistanceCaptures["subtotal"]?.source == "subtotal = factor * 2")
    let root = try #require(
      JSONSerialization.jsonObject(with: revised.permittedContext()) as? [String: Any])
    let dependencies = try #require(root["dependencySources"] as? [[String: String]])
    #expect(
      Set(dependencies.compactMap { $0["source"] }) == [
        "f(x) = x * subtotal", "subtotal = factor * 2", "factor = 10",
      ])
    #expect(
      !String(decoding: try revised.permittedContext(), as: UTF8.self).contains("factor = 99"))
  }

  @Test func transitiveContextRejectsExcessRecordsWithoutTruncation() throws {
    let chain = ["value0 = 1"] + (1...70).map { "value\($0) = value\($0 - 1) + 1" }
    let source = SheetSource((chain + ["Use value70 with two."]).joined(separator: "\n"))
    var calculator = SheetCalculator()
    let snapshot = try calculator.assistanceSnapshot(
      source, context: sheetContext(), target: source.lines.last!.id)
    #expect(throws: AssistanceSnapshotError.contextTooLarge) { try snapshot.permittedContext() }
  }

}
