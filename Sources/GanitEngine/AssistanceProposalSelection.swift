import GanitSuggestionProtocol

extension AssistanceCandidateChecker {
  /// Keep source rows that the reader did not select. Check the revised candidate before Apply.
  package static func selectingLines(
    _ candidate: SuggestionCandidate, against snapshot: AssistanceSnapshot,
    omitted: Set<Int>, choices: [String: String]
  ) throws -> SuggestionCandidate {
    guard omitted.isEmpty == false else { return candidate }
    let rows = SheetSource(candidate.edits[0].replacement).lines
    var kept: [(text: String, terminator: String?)] = []
    var handles: [String: String] = [:]
    for index in 0..<max(rows.count, snapshot.targetLines.count) {
      if omitted.contains(index) {
        if snapshot.targetLines.indices.contains(index) {
          let original = snapshot.targetLines[index]
          kept.append((original.text, original.terminator?.rawValue))
        }
      } else if rows.indices.contains(index) {
        handles["L\(index + 1)"] = "L\(kept.count + 1)"
        kept.append((rows[index].text, rows[index].terminator?.rawValue))
      }
    }
    let separator = snapshot.targetLines.first?.terminator?.rawValue ?? "\n"
    let replacement = kept.enumerated().map { index, row in
      row.text + (index + 1 < kept.count ? row.terminator ?? separator : "")
    }.joined()
    guard !replacement.isEmpty, replacement != snapshot.targetText else {
      throw AssistanceValidationFailure(
        .unsupportedOperation, "Select at least one proposed change.")
    }
    let bindings = candidate.bindings.map {
      SuggestionBinding(symbol: $0.symbol, source: handles[$0.source] ?? $0.source)
    }
    func revised(bindings: [SuggestionBinding], literals: [SuggestionLiteral])
      -> SuggestionCandidate
    {
      SuggestionCandidate(
        id: candidate.id, edits: [SuggestionEdit(target: "T1", replacement: replacement)],
        bindings: bindings, literals: literals, relations: candidate.relations,
        assumptions: candidate.assumptions, summary: candidate.summary)
    }
    let plan = try AssistanceProposalPlan(
      revised(bindings: bindings, literals: candidate.literals), snapshot: snapshot,
      choices: choices)
    let facts = plan.facts
    let used = facts.identifiers.union(facts.calls).union(
      plan.referenceNumbers.keys.map { "@\($0)" })
    var literals = candidate.literals.filter { claim in
      guard
        case .value(let value) = snapshot.scope.engine.evaluate(
          claim.text, context: snapshot.context)
      else { return false }
      return facts.literals.contains {
        assistanceLiteralValuesEqual($0.value, value, context: snapshot.context)
      }
    }
    // Retained source calculations use the same frozen evidence as the proposal.
    for literal in facts.literals {
      guard
        let evidence = snapshot.evidence().first(where: {
          $0.kind == "literal"
            && $0.value.map {
              assistanceLiteralValuesEqual($0, literal.value, context: snapshot.context)
            } == true
        })
      else { continue }
      let claim = SuggestionLiteral(text: literal.source, evidence: evidence.handle)
      if !literals.contains(claim) { literals.append(claim) }
    }
    return revised(
      bindings: bindings.filter { used.contains($0.symbol.lowercased()) }, literals: literals)
  }
}
