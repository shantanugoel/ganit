import Foundation
import GanitSuggestionProtocol
import Testing

@testable import GanitEngine

@Suite
struct AssistanceSharingTests {
  private let dinner =
    "# Dinner\nsecret = 9876\nbill = 2400 INR\n@2 + 1\nAdd a 10% tip to bill, then split it four ways."

  private func snapshot(_ text: String) throws -> AssistanceSnapshot {
    var calculator = SheetCalculator()
    let sheet = SheetSource(text)
    return try calculator.assistanceSnapshot(
      sheet, context: sheetContext(), target: sheet.lines.last!.id)
  }

  private func root(_ snapshot: AssistanceSnapshot, _ sharing: AssistantContextSharing) throws
    -> [String: Any]
  {
    try #require(
      JSONSerialization.jsonObject(with: snapshot.permittedContext(sharing: sharing))
        as? [String: Any])
  }

  @Test func onlyWhatIsNeededIsTheRequestFromBeforeTheSetting() throws {
    let snapshot = try snapshot(dinner)
    #expect(try snapshot.permittedContext(sharing: .needed) == snapshot.permittedContext())
    let root = try root(snapshot, .needed)
    #expect(root["index"] == nil)
    #expect(root["sheet"] == nil)
  }

  @Test func namesListOtherRecordsWithoutTheirValues() throws {
    let snapshot = try snapshot(dinner)
    let root = try root(snapshot, .names)
    let index = try #require(root["index"] as? [[String: Any]])
    #expect(index.compactMap { $0["name"] as? String } == ["secret"])
    #expect(index.first?["kind"] as? String == "variable")
    let secret = try #require(snapshot.inventory.first { $0.name == "secret" })
    #expect(index.first?["handle"] as? String == secret.handle)
    let symbols = try #require(root["symbols"] as? [[String: Any]])
    #expect(!symbols.contains { $0["name"] as? String == "secret" })
    #expect(
      !String(decoding: try snapshot.permittedContext(sharing: .names), as: UTF8.self)
        .contains("9876"))
    #expect(root["sheet"] == nil)
  }

  @Test func namesStartNearestTheTargetAndStopAtTheLimit() throws {
    let count = AssistantContextSharing.indexLimit + 6
    let lines = (1...count).map { "v\($0) = \($0)" } + ["Add a tip to the bill."]
    let snapshot = try snapshot(lines.joined(separator: "\n"))
    let index = try #require(try root(snapshot, .names)["index"] as? [[String: Any]])
    #expect(index.count == AssistantContextSharing.indexLimit)
    #expect(index.first?["name"] as? String == "v\(count)")
    #expect(!index.contains { $0["name"] as? String == "v1" })
  }

  @Test func wholeSheetSendsEveryRecordAndTheSheetText() throws {
    let snapshot = try snapshot(dinner)
    let root = try root(snapshot, .sheet)
    #expect(root["sheet"] as? String == snapshot.source.text)
    let symbols = try #require(root["symbols"] as? [[String: Any]])
    #expect(
      Set(symbols.compactMap { $0["handle"] as? String })
        == Set(snapshot.inventory.map(\.handle)))
    #expect(root["index"] == nil)
  }

  @Test func tooManyRecordsKeepTheSheetTextAndListTheNames() throws {
    let lines = (1...(SuggestionLimits.symbols + 6)).map { "v\($0) = \($0)" } + ["Add v1 to v2."]
    let snapshot = try snapshot(lines.joined(separator: "\n"))
    let root = try root(snapshot, .sheet)
    #expect(root["sheet"] as? String == snapshot.source.text)
    let symbols = try #require(root["symbols"] as? [[String: Any]])
    #expect(Set(symbols.compactMap { $0["name"] as? String }) == ["v1", "v2"])
    #expect((root["index"] as? [[String: Any]])?.isEmpty == false)
  }

  @Test func aSheetTooLongToSendFallsBackToNames() throws {
    let note = "// " + String(repeating: "a", count: 1_000)
    let lines =
      ["secret = 9876"] + Array(repeating: note, count: 70) + ["bill = 10", "Add a tip to bill."]
    let snapshot = try snapshot(lines.joined(separator: "\n"))
    let root = try root(snapshot, .sheet)
    #expect(root["sheet"] == nil)
    let index = try #require(root["index"] as? [[String: Any]])
    #expect(index.compactMap { $0["name"] as? String } == ["secret"])
  }
}
