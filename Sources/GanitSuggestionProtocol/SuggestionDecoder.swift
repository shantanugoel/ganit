import CoreFoundation
import Foundation

/// Decode the complete JSON response. Source and reasoning text are not answers.
public enum SuggestionDecoder {
  public static func decode(_ data: Data) throws -> SuggestionOutcome {
    guard data.count <= SuggestionLimits.payloadBytes else {
      throw SuggestionDecodingError.payloadTooLarge
    }
    guard String(data: data, encoding: .utf8) != nil else {
      throw SuggestionDecodingError.invalidSchema
    }
    var syntax = StrictSuggestionJSON(data)
    try syntax.check()
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any],
      let version = root["schemaVersion"] as? NSNumber,
      CFGetTypeID(version) != CFBooleanGetTypeID(),
      version == NSNumber(value: SuggestionLimits.schemaVersion)
    else { throw SuggestionDecodingError.unsupportedVersion }
    guard let kind = root["kind"] as? String else {
      throw SuggestionDecodingError.invalidSchema
    }
    switch kind {
    case "explanation":
      try keys(root, required: ["schemaVersion", "kind", "text"])
      let value = try text(root, "text", bytes: 8_192)
      guard
        !value.unicodeScalars.contains(where: { scalar in
          switch scalar.properties.generalCategory {
          case .decimalNumber, .letterNumber, .otherNumber: return true
          default: return "=+*/%×÷".unicodeScalars.contains(scalar)
          }
        })
      else { throw SuggestionDecodingError.invalidSchema }
      return .explanation(value)
    case "proposal":
      try keys(root, required: ["schemaVersion", "kind", "candidates"])
      guard data.count <= SuggestionLimits.proposalBytes else {
        throw SuggestionDecodingError.proposalTooLarge
      }
      let candidates = try objects(root, "candidates", count: 1...SuggestionLimits.candidates)
      var result: [SuggestionCandidate] = []
      var ids: Set<String> = []
      for candidate in candidates {
        try keys(
          candidate,
          required: [
            "id", "edits", "bindings", "literals", "relations", "assumptions", "summary",
          ])
        let id = try text(candidate, "id", bytes: 64)
        guard ids.insert(id).inserted else { throw SuggestionDecodingError.invalidSchema }
        _ = try text(candidate, "summary", bytes: 2_048)
        let edits = try objects(candidate, "edits", count: 1...12)
        var targets: Set<String> = []
        for edit in edits {
          try keys(edit, required: ["target", "replacement"])
          let target = try text(edit, "target", bytes: 64)
          guard targets.insert(target).inserted else {
            throw SuggestionDecodingError.invalidSchema
          }
          let replacement = try text(edit, "replacement", bytes: SuggestionLimits.replacementBytes)
          guard
            replacement.split(
              omittingEmptySubsequences: false,
              whereSeparator: {
                $0 == "\n" || $0 == "\r" || $0 == "\r\n"
              }
            ).count
              <= SuggestionLimits.replacementLines
          else { throw SuggestionDecodingError.invalidBounds }
        }
        try records(candidate, "bindings", fields: ["symbol", "source"], count: 0...64)
        try records(candidate, "literals", fields: ["text", "evidence"], count: 0...128)
        try records(candidate, "relations", fields: ["rule", "evidence"], count: 0...64)
        try records(candidate, "assumptions", fields: ["id", "text", "evidence"], count: 0...16)
        result.append(try typed(candidate, as: SuggestionCandidate.self))
      }
      return .proposal(result)
    case "clarify":
      try keys(
        root, required: ["schemaVersion", "kind", "question", "choices"], optional: ["missingInput"]
      )
      let question = try text(root, "question", bytes: 2_048)
      guard let choices = root["choices"] as? [String], choices.count <= 3,
        choices.allSatisfy({
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 512
        }),
        Set(choices).count == choices.count
      else { throw SuggestionDecodingError.invalidBounds }
      let missing = try root["missingInput"].map { _ in
        try text(root, "missingInput", bytes: 512)
      }
      guard !choices.isEmpty || missing != nil else {
        throw SuggestionDecodingError.invalidSchema
      }
      return .clarify(
        SuggestionClarification(question: question, choices: choices, missingInput: missing))
    case "need_context":
      try keys(root, required: ["schemaVersion", "kind", "records", "reason"])
      guard let records = root["records"] as? [String], (1...64).contains(records.count),
        records.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
        Set(records).count == records.count
      else { throw SuggestionDecodingError.invalidBounds }
      return .needContext(records: records, reason: try text(root, "reason", bytes: 2_048))
    case "unsupported":
      try keys(root, required: ["schemaVersion", "kind", "reason"])
      return .unsupported(reason: try text(root, "reason", bytes: 2_048))
    default:
      throw SuggestionDecodingError.invalidSchema
    }
  }

  private static func keys(
    _ object: [String: Any], required: Set<String>, optional: Set<String> = []
  ) throws {
    let actual = Set(object.keys)
    guard required.isSubset(of: actual), actual.isSubset(of: required.union(optional)) else {
      throw SuggestionDecodingError.invalidSchema
    }
  }

  private static func text(_ object: [String: Any], _ key: String, bytes: Int) throws -> String {
    guard let value = object[key] as? String,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= bytes
    else { throw SuggestionDecodingError.invalidBounds }
    return value
  }

  private static func objects(_ object: [String: Any], _ key: String, count: ClosedRange<Int>)
    throws
    -> [[String: Any]]
  {
    guard let values = object[key] as? [[String: Any]], count.contains(values.count) else {
      throw SuggestionDecodingError.invalidBounds
    }
    return values
  }

  private static func records(
    _ object: [String: Any], _ key: String, fields: Set<String>, count: ClosedRange<Int>
  ) throws {
    for record in try objects(object, key, count: count) {
      try keys(record, required: fields)
      for field in fields {
        _ = try text(record, field, bytes: field == "text" ? 2_048 : 256)
      }
    }
  }

  private static func typed<T: Decodable>(_ object: [String: Any], as type: T.Type) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    } catch { throw SuggestionDecodingError.invalidSchema }
  }
}
