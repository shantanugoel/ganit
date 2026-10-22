import Foundation
import Testing

@testable import GanitEngine

@Suite
struct SheetExplanationTests {
  @Test func percentageReadsTheNativeAnswer() throws {
    let sheet = SheetSource("4000\n5200\nsubtotal\n10% of line 3")
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[3].id))
    #expect(explanation.expression == "10% of line 3")
    #expect(explanation.result == .value(.number(.integer(IntegerValue(920)))))
    #expect(explanation.result == evaluation.lines[3].result)
    #expect(explanation.expressionTree != nil)
    #expect(explanation.dependencies.map(\.lineNumber) == [1, 2, 3])
    #expect(explanation.grammarRules.contains("X% of Y calculates X / 100 × Y."))
    #expect(explanation.grammarRules.contains("line 3 reads the answer of line 3."))
    #expect(explanation.diagnostics.isEmpty)
  }

  @Test func declarationsUseTheirOriginalScope() throws {
    let sheet = SheetSource("cost = 10\ncost = cost + 2\nanswer = cost * 2\n---\ncost + 1")
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[2].id))
    #expect(explanation.dependencies.map(\.lineNumber) == [1, 2])
    #expect(explanation.result == .value(.number(.integer(IntegerValue(24)))))
    #expect(evaluation.explanation(for: sheet.lines[4].id)?.dependencies.isEmpty == true)
  }

  @Test func assumptionsComeFromTheNativeDependencyGraph() throws {
    let sheet = SheetSource(
      "density = 1000 kg/m^3 // AI: density of water · test · 2026-10-22\nvolume = 2 m^3\nmass = density * volume"
    )
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[2].id))
    #expect(explanation.assumptions.map(\.lineNumber) == [1])
    #expect(explanation.assumptions.first?.assumption.basis == "density of water")
    #expect(explanation.dependencies.map(\.lineNumber) == [1, 2])
  }

  @Test func aRenumberedFailureNamesTheCurrentLine() throws {
    let original = "10\n1 / 0\nline 2 + 3"
    let edits = LineReferenceRenumbering.edits(
      replacing: NSRange(location: 0, length: 0), in: original, with: "20\n",
      configuration: .englishUnitedStates)
    let text = NSMutableString(string: original)
    text.insert("20\n", at: 0)
    for edit in edits.reversed() { text.replaceCharacters(in: edit.range, with: edit.replacement) }
    let sheet = SheetSource(text as String)
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[3].id))
    #expect(explanation.expression == "line 3 + 3")
    #expect(explanation.failureOriginLineNumbers == [3])
    #expect(explanation.dependencies.map(\.lineNumber) == [3])
    #expect(explanation.result == evaluation.lines[3].result)
    #expect(!explanation.diagnostics.isEmpty)
    // The reader wrote `line 2`; after the insertion above it reads line 3, and
    // the explanation names the line it reads now, with its current text.
    #expect(
      explanation.staleReferences
        == [SheetExplanationReference(written: "line 3", lineNumber: 3, targetSource: "1 / 0")]
    )
  }

  @Test func aReferenceToAnUnreadableLineSaysWhatItReadsNow() throws {
    var calculator = SheetCalculator()

    let blank = SheetSource("cost = 10\n\nsubtotal = cost + line 2")
    let blankEvaluation = try calculator.evaluate(blank, context: sheetContext())
    #expect(
      blankEvaluation.explanation(for: blank.lines[2].id)?.staleReferences
        == [SheetExplanationReference(written: "line 2", lineNumber: 2, targetSource: "")]
    )

    let heading = SheetSource("# Title\n\ntotal = line 1 + 1")
    let headingEvaluation = try calculator.evaluate(heading, context: sheetContext())
    #expect(
      headingEvaluation.explanation(for: heading.lines[2].id)?.staleReferences
        == [SheetExplanationReference(written: "line 1", lineNumber: 1, targetSource: "# Title")]
    )

    let missing = SheetSource("total = line 9 + 1")
    let missingEvaluation = try calculator.evaluate(missing, context: sheetContext())
    #expect(
      missingEvaluation.explanation(for: missing.lines[0].id)?.staleReferences
        == [SheetExplanationReference(written: "line 9", lineNumber: 9, targetSource: nil)]
    )

    // A reference that reads an answer is not a cause of anything.
    let good = SheetSource("cost = 10\ntotal = cost + line 1")
    let goodEvaluation = try calculator.evaluate(good, context: sheetContext())
    #expect(goodEvaluation.explanation(for: good.lines[1].id)?.staleReferences.isEmpty == true)
    // A broken marker names its own cause, so it is not repeated here.
    let broken = SheetSource("10\ntotal = line 99 + @deleted")
    let brokenEvaluation = try calculator.evaluate(broken, context: sheetContext())
    #expect(
      brokenEvaluation.explanation(for: broken.lines[1].id)?.staleReferences
        == [SheetExplanationReference(written: "line 99", lineNumber: 99, targetSource: nil)]
    )
  }

  @Test func brokenReferencesUseTheNativeCause() throws {
    for marker in ["@deleted", "@split"] {
      let sheet = SheetSource("10\n" + marker)
      var calculator = SheetCalculator()
      let evaluation = try calculator.evaluate(sheet, context: sheetContext())
      let explanation = try #require(evaluation.explanation(for: sheet.lines[1].id))
      #expect(explanation.result == evaluation.lines[1].result)
      #expect(explanation.dependencies.isEmpty)
      #expect(explanation.grammarRules.contains { $0.contains("Select a new reference") })
      #expect(!explanation.diagnostics.isEmpty)
    }
  }

  @Test func customUnitsReadTheirDefinition() throws {
    let sheet = SheetSource("1 bag = 25 kg\n3 bags in kg")
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[1].id))
    #expect(explanation.dependencies.map(\.lineNumber) == [1])
    #expect(explanation.result == evaluation.lines[1].result)
  }

  @Test func unavailableForwardDefinitionsDoNotInventDependencies() throws {
    for source in [
      "3 bags in kg\n1 bag = 25 kg",
      "f(2)\ncost = 10\nf(x) = x + cost",
      "f(2)\ng(x) = x + 1\nf(x) = g(x)",
    ] {
      let sheet = SheetSource(source)
      var calculator = SheetCalculator()
      let evaluation = try calculator.evaluate(sheet, context: sheetContext())
      let explanation = try #require(evaluation.explanation(for: sheet.lines[0].id))
      #expect(explanation.dependencies.isEmpty)
      #expect(!explanation.diagnostics.isEmpty)
      #expect(explanation.result == evaluation.lines[0].result)
    }
  }

  @Test func parametersDoNotReadAnEarlierVariableWithTheSameName() throws {
    let sheet = SheetSource("cost = 10\nf(cost) = cost + 1\nf(2)")
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[2].id))
    #expect(explanation.dependencies.map(\.lineNumber) == [2])
    #expect(explanation.result == .value(.number(.integer(IntegerValue(3)))))
  }

  @Test func syntaxFailuresKeepNativeRanges() throws {
    let sheet = SheetSource("2 + (3")
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[0].id))
    #expect(explanation.expression == "2 + (3")
    #expect(explanation.expressionTree == nil)
    #expect(explanation.result == evaluation.lines[0].result)
    #expect(!explanation.diagnostics.isEmpty)
  }

  @Test func functionCapturesKeepTheirDeclarationScope() throws {
    let sheet = SheetSource("cost = 10\nf(x) = x + cost\ncost = 30\nf(2)")
    var calculator = SheetCalculator()
    let evaluation = try calculator.evaluate(sheet, context: sheetContext())
    let explanation = try #require(evaluation.explanation(for: sheet.lines[3].id))
    #expect(explanation.dependencies.map(\.lineNumber) == [1, 2])
    #expect(explanation.result == .value(.number(.integer(IntegerValue(12)))))
  }
}
