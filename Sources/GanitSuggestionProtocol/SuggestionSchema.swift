import Foundation

/// The versioned response schema sent to providers that support JSON schemas.
public enum SuggestionSchema {
  public static func data(allowsExplanation: Bool = false) throws -> Data {
    var schema = document
    if allowsExplanation {
      var branches = schema["oneOf"] as! [[String: Any]]
      branches.append(root("explanation", ["text": string(bytes: 8_192)]))
      schema["oneOf"] = branches
    }
    return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
  }

  private static var document: [String: Any] {
    let edit = object([
      "target": string(bytes: 64),
      "replacement": string(
        bytes: SuggestionLimits.replacementBytes, lines: SuggestionLimits.replacementLines),
    ])
    let binding = object(["symbol": string(bytes: 256), "source": string(bytes: 256)])
    let literal = object(["text": string(bytes: 2_048), "evidence": string(bytes: 256)])
    let relation = object(["rule": string(bytes: 256), "evidence": string(bytes: 256)])
    let assumption = object([
      "id": string(bytes: 256), "text": string(bytes: 2_048), "evidence": string(bytes: 256),
    ])
    let candidate = object([
      "id": string(bytes: 64), "edits": array(edit, count: 1...12),
      "bindings": array(binding, count: 0...64), "literals": array(literal, count: 0...128),
      "relations": array(relation, count: 0...64), "assumptions": array(assumption, count: 0...16),
      "summary": string(bytes: 2_048),
    ])
    var clarification = root(
      "clarify",
      [
        "question": string(bytes: 2_048),
        "choices": array(string(bytes: 512), count: 0...3, unique: true),
        "missingInput": string(bytes: 512),
      ])
    clarification["required"] = ["schemaVersion", "kind", "question", "choices"]
    clarification["anyOf"] = [
      ["properties": ["choices": ["minItems": 1]]],
      ["required": ["missingInput"]],
    ]
    return [
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "urn:ganit:suggestion-response:1",
      "oneOf": [
        root("proposal", ["candidates": array(candidate, count: 1...SuggestionLimits.candidates)]),
        clarification,
        root(
          "need_context",
          [
            "records": array(string(bytes: 64), count: 1...64, unique: true),
            "reason": string(bytes: 2_048),
          ]),
        root("unsupported", ["reason": string(bytes: 2_048)]),
      ],
    ]
  }

  private static func root(_ kind: String, _ properties: [String: Any]) -> [String: Any] {
    var properties = properties
    properties["schemaVersion"] = ["type": "integer", "const": SuggestionLimits.schemaVersion]
    properties["kind"] = ["type": "string", "const": kind]
    return object(properties)
  }

  private static func object(_ properties: [String: Any]) -> [String: Any] {
    [
      "type": "object", "additionalProperties": false,
      "properties": properties, "required": properties.keys.sorted(),
    ]
  }

  private static func string(bytes: Int, lines: Int? = nil) -> [String: Any] {
    var schema: [String: Any] = [
      "type": "string", "minLength": 1, "maxLength": bytes,
      "pattern": "\\S", "x-maxUtf8Bytes": bytes,
    ]
    if let lines { schema["x-maxPhysicalLines"] = lines }
    return schema
  }

  private static func array(_ item: [String: Any], count: ClosedRange<Int>, unique: Bool = false)
    -> [String: Any]
  {
    var schema: [String: Any] = [
      "type": "array", "items": item, "minItems": count.lowerBound, "maxItems": count.upperBound,
    ]
    if unique { schema["uniqueItems"] = true }
    return schema
  }
}
