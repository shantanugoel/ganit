import Foundation

/// The limits for one suggestion job. All text limits use UTF-8 bytes.
public enum SuggestionLimits {
  public static let schemaVersion = 1
  public static let targetBytes = 8 * 1_024
  public static let targetLines = 12
  public static let contextBytes = 24 * 1_024
  public static let symbols = 64
  public static let requestBytes = 64 * 1_024
  public static let payloadBytes = 256 * 1_024
  public static let proposalBytes = 32 * 1_024
  public static let candidates = 3
  public static let replacementBytes = 4 * 1_024
  public static let replacementLines = 16
  public static let requestsPerJob = 3
}

public struct SuggestionEdit: Codable, Equatable, Sendable {
  public let target: String
  public let replacement: String

  public init(target: String, replacement: String) {
    self.target = target
    self.replacement = replacement
  }
}

public struct SuggestionBinding: Codable, Equatable, Sendable {
  public let symbol: String
  public let source: String

  public init(symbol: String, source: String) {
    self.symbol = symbol
    self.source = source
  }
}

public struct SuggestionLiteral: Codable, Equatable, Sendable {
  public let text: String
  public let evidence: String

  public init(text: String, evidence: String) {
    self.text = text
    self.evidence = evidence
  }
}

public struct SuggestionRelation: Codable, Equatable, Sendable {
  public let rule: String
  public let evidence: String

  public init(rule: String, evidence: String) {
    self.rule = rule
    self.evidence = evidence
  }
}

/// An assumption needs a user choice before the source can change.
public struct SuggestionAssumption: Codable, Equatable, Sendable {
  public let id: String
  public let text: String
  public let evidence: String

  public init(id: String, text: String, evidence: String) {
    self.id = id
    self.text = text
    self.evidence = evidence
  }
}

public struct SuggestionCandidate: Codable, Equatable, Sendable {
  public let id: String
  public let edits: [SuggestionEdit]
  public let bindings: [SuggestionBinding]
  public let literals: [SuggestionLiteral]
  public let relations: [SuggestionRelation]
  public let assumptions: [SuggestionAssumption]
  public let summary: String

  public init(
    id: String, edits: [SuggestionEdit], bindings: [SuggestionBinding],
    literals: [SuggestionLiteral], relations: [SuggestionRelation],
    assumptions: [SuggestionAssumption], summary: String
  ) {
    self.id = id
    self.edits = edits
    self.bindings = bindings
    self.literals = literals
    self.relations = relations
    self.assumptions = assumptions
    self.summary = summary
  }
}

public struct SuggestionClarification: Codable, Equatable, Sendable {
  public let question: String
  public let choices: [String]
  public let missingInput: String?

  public init(question: String, choices: [String], missingInput: String? = nil) {
    self.question = question
    self.choices = choices
    self.missingInput = missingInput
  }
}

public enum SuggestionOutcome: Equatable, Sendable {
  case proposal([SuggestionCandidate])
  case clarify(SuggestionClarification)
  case needContext(records: [String], reason: String)
  case unsupported(reason: String)
}

public enum SuggestionDecodingError: Error, Equatable, Sendable {
  case payloadTooLarge
  case proposalTooLarge
  case invalidSchema
  case unsupportedVersion
  case invalidBounds
}
