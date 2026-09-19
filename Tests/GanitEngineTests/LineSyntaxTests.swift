import Foundation
import Testing

@testable import GanitEngine

@Suite
struct LineSyntaxTests {
  @Test
  func classifiesBlankDividerHeadingAndComment() {
    let lines = [
      "", "   \t", "---", "  -----  ", "--", "---5", "# Monthly budget ", "#", "  // note",
    ]
    let syntax = lines.map(LineSyntax.init)

    #expect(syntax[0] == .blank)
    #expect(syntax[1] == .blank)
    #expect(syntax[2] == .divider)
    #expect(syntax[3] == .divider)
    #expect(expressionText(syntax[4], in: lines[4]) == "--")
    #expect(expressionText(syntax[5], in: lines[5]) == "---5")
    guard case .heading(let title) = syntax[6], case .heading(let empty) = syntax[7]
    else {
      Issue.record("Expected headings")
      return
    }
    #expect(title.text(in: lines[6]) == "Monthly budget")
    #expect(empty.isEmpty)
    guard case .comment(let comment) = syntax[8] else {
      Issue.record("Expected a comment")
      return
    }
    #expect(comment.text(in: lines[8]) == "// note")
  }

  @Test
  func separatesLabelsExpressionsAndTrailingComments() {
    let cases: [(String, label: String?, expression: String?, comment: String?)] = [
      ("12 km in miles // commute", nil, "12 km in miles", "// commute"),
      ("Rent: 2100", "Rent", "2100", nil),
      ("  Café ☕ :  3 m // shared ", "Café ☕", "3 m", "// shared"),
      ("Groceries:", "Groceries", nil, nil),
      ("Savings: // later", "Savings", nil, "// later"),
      ("10:30", nil, "10:30", nil),
      (": 5", nil, ": 5", nil),
      ("Q1: 20% of 50", "Q1", "20% of 50", nil),
      ("2 + 2 =>", nil, "2 + 2", nil),
      ("Total: 10 + 5 => leftover", "Total", "10 + 5", nil),
    ]

    for (source, label, expression, comment) in cases {
      guard
        case .calculation(let labelRange, nil, let expressionRange, let commentRange) =
          LineSyntax(source)
      else {
        Issue.record("Expected a calculation for \(source)")
        continue
      }
      #expect(labelRange?.text(in: source).map(String.init) == label, "\(source)")
      #expect(
        expressionRange?.text(in: source).map(String.init) == expression,
        "\(source)"
      )
      #expect(commentRange?.text(in: source).map(String.init) == comment, "\(source)")
    }
  }

  @Test
  func findsTheArrowEndingACalculation() {
    #expect(
      LineSyntax.arrow(in: "Each pays 555 / 3 => then a hotel")?.text(
        in: "Each pays 555 / 3 => then a hotel") == "=>")
    #expect(LineSyntax.arrow(in: "x = 2 => ")?.lowerBound == 6)
    #expect(LineSyntax.arrow(in: "2 + 2") == nil)
    #expect(LineSyntax.arrow(in: "# Heading =>") == nil)
    #expect(LineSyntax.arrow(in: "// note =>") == nil)
    #expect(LineSyntax.arrow(in: "2 // then =>") == nil)
  }

  @Test
  func evaluatesSheetLinesWithLineRelativeRanges() throws {
    let sheet = SheetSource(
      "# Trip\r\nDistance: 12 km in miles // one way\n\n---\nBad: 1 m + 1 s\nTotal: 2 +\n"
    )
    let results = try evaluateSheet(sheet)

    #expect(results.map(\.id) == sheet.lines.map(\.id))
    #expect(results[0].result == nil)
    guard case .value(.quantity) = results[1].result else {
      Issue.record("Expected a converted quantity")
      return
    }
    #expect(results[2].result == nil)
    #expect(results[3].result == nil)

    guard case .evaluationFailure(let error) = results[4].result else {
      Issue.record("Expected a dimension failure")
      return
    }
    #expect(error.code == .incompatibleDimensions)
    #expect(error.ranges.first?.text(in: sheet.lines[4].text) == "+")

    guard case .syntaxFailure(let diagnostics) = results[5].result else {
      Issue.record("Expected an incomplete expression")
      return
    }
    let diagnostic = try #require(diagnostics.first)
    #expect(diagnostic.severity == .incomplete)
    #expect(diagnostic.range.lowerBound == sheet.lines[5].text.utf8.count)
    #expect(diagnostic.range.graphemeLowerBound == sheet.lines[5].text.count)
  }

  @Test
  func lexerOffsetsRangesByOrigin() {
    let origin = SourceLocation(utf8Offset: 10, graphemeOffset: 7)
    let local = Lexer(source: "π + 2").lex().tokens.map(\.range)
    let shifted = Lexer(source: "π + 2", origin: origin).lex().tokens.map(\.range)

    #expect(
      shifted
        == local.map {
          SourceRange(
            lowerBound: $0.lowerBound + 10,
            upperBound: $0.upperBound + 10,
            graphemeLowerBound: $0.graphemeLowerBound + 7,
            graphemeUpperBound: $0.graphemeUpperBound + 7
          )
        }
    )
  }

  private func expressionText(_ syntax: LineSyntax, in text: String) -> Substring? {
    guard case .calculation(nil, nil, let expression?, nil) = syntax else {
      return nil
    }
    return expression.text(in: text)
  }
}
