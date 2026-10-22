import Foundation
import GanitSuggestionProtocol

/// A complete source transaction checked locally, including retained working.
public struct AssistanceSourceEdit: Sendable {
  public let sourceBefore: String
  public let sourceAfter: String
  public let target: LineID
  public let evaluation: SheetEvaluation
  public let checked: AssistanceCheckedCandidate
  package let referenceMapping: [Int: Int]
  package let patches: [TableSourcePatch]
}

extension AssistanceCandidateChecker {
  /// Call with a fresh snapshot immediately before source application.
  public static func prepareSourceEdit(
    _ candidate: SuggestionCandidate, against snapshot: AssistanceSnapshot,
    permittedHandles: Set<String> = [], selectedChoices: [String: String] = [:],
    approvedAssumptions: Set<String> = [], userRevisedInputs: Bool = false,
    assumptionModel: String = "AI", assumptionDate: String? = nil
  ) throws -> AssistanceSourceEdit {
    let checked = try check(
      candidate, against: snapshot, permittedHandles: permittedHandles,
      selectedChoices: selectedChoices, approvedAssumptions: approvedAssumptions,
      userRevisedInputs: userRevisedInputs)
    guard checked.isApplicable else {
      throw AssistanceValidationFailure(.relation, "Review each required choice and assumption.")
    }
    let evidence = Dictionary(
      uniqueKeysWithValues: snapshot.evidence(including: permittedHandles).map { ($0.handle, $0) })
    let assumed = try AssistanceAssumptionDeclaration.validate(
      candidate, snapshot: snapshot, evidence: evidence)
    var working = candidate.edits[0].replacement
    if let assumed, let assumption = candidate.assumptions.first {
      let date =
        assumptionDate
        ?? String(ISO8601DateFormatter().string(from: snapshot.context.now).prefix(10))
      let marker = AIAssumption(
        basis: oneLine(assumption.text),
        model: oneLine(assumptionModel).replacingOccurrences(of: " · ", with: " ")
          .trimmingCharacters(in: .whitespaces), date: date)
      let rows = SheetSource(working).lines
      guard
        AIAssumption.parse(
          rows[assumed.lineIndex].text + " " + marker.comment, context: snapshot.context) != nil
      else {
        throw AssistanceValidationFailure(
          .invalidBounds, "The assumption origin needs a model and a valid date.")
      }
      working = rows.enumerated().map { index, line in
        line.text + (index == assumed.lineIndex ? " " + marker.comment : "")
          + (line.terminator?.rawValue ?? "")
      }.joined()
    }
    let target = snapshot.targetLines.last!
    let separator = target.terminator?.rawValue ?? "\n"
    var comments = snapshot.targetLines.map { "// Request record: " + $0.text }
    comments += snapshot.notes.filter { $0.source.hasPrefix("// Task: ") }.map {
      "// Task record: " + String($0.source.dropFirst("// Task: ".count))
    }
    // Put historical records after the proposed working. Existing references
    // use the reviewed mapping through the same source transaction.
    let insertion = target.range.upperBound + (target.terminator?.rawValue.utf8.count ?? 0)
    let record =
      (target.terminator == nil ? separator : "")
      + comments.joined(separator: separator) + (target.terminator == nil ? "" : separator)
    let workingPatches = checked.patches.map {
      TableSourcePatch(utf8Range: $0.utf8Range, expected: $0.expected, replacement: working)
    }
    let patches =
      workingPatches + [
        TableSourcePatch(utf8Range: insertion..<insertion, expected: "", replacement: record)
      ]
    var shadow = snapshot.source
    for patch in patches.sorted(by: { $0.utf8Range.lowerBound > $1.utf8Range.lowerBound }) {
      shadow.replace(utf8Range: patch.utf8Range, with: patch.replacement)
    }
    let original = snapshot.source.text
    let ranges = patches.map { patch -> NSRange in
      let utf8 = original.utf8
      let lower = utf8.index(utf8.startIndex, offsetBy: patch.utf8Range.lowerBound)
      let upper = utf8.index(utf8.startIndex, offsetBy: patch.utf8Range.upperBound)
      return NSRange(lower..<upper, in: original)
    }
    let rewrites = LineReferenceRenumbering.edits(
      replacing: ranges, in: original, with: patches.map(\.replacement),
      configuration: snapshot.context.lexingConfiguration,
      targetLineMapping: checked.referenceMapping)
    for rewrite in rewrites.reversed() {
      let text = shadow.text
      guard let range = Range(rewrite.range, in: text) else {
        throw AssistanceValidationFailure(
          .invalidBounds, "The reference edit is outside the source.")
      }
      let lower = text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
      let upper = text.utf8.distance(from: text.utf8.startIndex, to: range.upperBound)
      shadow.replace(utf8Range: lower..<upper, with: rewrite.replacement)
    }
    let context = snapshot.context.with(assistantAnswers: [:])
    var calculator = snapshot.calculator
    let baseline = try calculator.evaluate(snapshot.source, context: context)
    let evaluation = try calculator.evaluate(shadow, context: context)
    let outputCount = SheetSource(candidate.edits[0].replacement).lines.count
    guard let firstOutput = shadow.lines.firstIndex(where: { $0.id == snapshot.target.id }),
      firstOutput + outputCount <= shadow.lines.count
    else {
      throw AssistanceValidationFailure(
        .invalidBounds, "The result line no longer has its source identity.")
    }
    guard
      let checkedStart = checked.evaluation.lines.firstIndex(where: { $0.id == snapshot.target.id }
      ),
      let checkedResult = checked.evaluation.lines.firstIndex(where: {
        $0.id == checked.resultLineID
      })
    else {
      throw AssistanceValidationFailure(.invalidBounds, "The checked result is unavailable.")
    }
    let resultID = shadow.lines[firstOutput + checkedResult - checkedStart].id
    guard let line = evaluation.lines.first(where: { $0.id == resultID }),
      case .value(let value) = line.result,
      assistanceValuesEqual(value, checked.result, context: context)
    else {
      throw AssistanceValidationFailure(.downstreamFailure, "The source record changes the result.")
    }
    let before = Dictionary(uniqueKeysWithValues: baseline.lines.map { ($0.id, $0.result) })
    let selectedIDs = Set(snapshot.targetLines.map(\.id))
    for line in evaluation.lines where !selectedIDs.contains(line.id) {
      switch line.result {
      case .syntaxFailure, .evaluationFailure:
        guard before[line.id] == .some(line.result) else {
          throw AssistanceValidationFailure(
            .downstreamFailure, "The complete edit introduces a downstream failure.",
            engineResult: line.result)
        }
      default: break
      }
    }
    for table in evaluation.tables {
      guard let current = table.calculation else { continue }
      let prior = baseline.tables.first { $0.projection?.id == current.table.id }?.calculation
      for (address, outcome) in current.outcomes {
        if case .failure = outcome, prior?.outcomes[address] != outcome {
          throw AssistanceValidationFailure(
            .downstreamFailure, "The complete edit introduces a table failure.")
        }
      }
    }
    return AssistanceSourceEdit(
      sourceBefore: original, sourceAfter: shadow.text, target: snapshot.target.id,
      evaluation: evaluation, checked: checked, referenceMapping: checked.referenceMapping,
      patches: patches)
  }

  private static func oneLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
  }
}
