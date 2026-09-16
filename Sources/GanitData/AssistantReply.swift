import Foundation

/// Turns a chat-completions reply into a short calculator value.
///
/// Models wrap answers in JSON, think-tags, markdown, or a sentence. The
/// answer column only has room for the value.
enum AssistantReply {
  /// The value hidden in `content`. A model's reasoning is its working, not
  /// an answer, so it counts only when it ends in the JSON value asked for.
  static func value(content: String?, reasoning: String? = nil) -> String? {
    if let value = value(in: content ?? "") {
      return value
    }
    guard let json = jsonValue(in: stripThinkBlocks(reasoning ?? "")) else {
      return nil
    }
    return value(in: json)
  }

  private static func value(in text: String) -> String? {
    var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      return nil
    }
    text = stripThinkBlocks(text)
    text = stripFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
    if let json = jsonValue(in: text) {
      text = json
    }
    text = stripDecorations(text)
    guard text.rangeOfCharacter(from: .alphanumerics) != nil,
      text.caseInsensitiveCompare("UNKNOWN") != .orderedSame,
      text.count <= Assistant.maximumAnswer
    else {
      return nil
    }
    return text
  }

  private static func stripThinkBlocks(_ text: String) -> String {
    var text = text
    let tags = ["think", "thinking", "reasoning", "reflection"]
    for tag in tags {
      // A model's working is usually several lines. `.` does not match those.
      let pattern = "<\(tag)>[\\s\\S]*?</\(tag)>"
      text = text.replacingOccurrences(
        of: pattern, with: " ", options: [.regularExpression, .caseInsensitive]
      )
    }
    if let close = tags.compactMap({ tag in
      text.range(of: "</\(tag)>", options: [.caseInsensitive, .backwards])
    }).max(by: { $0.upperBound < $1.upperBound }) {
      text = String(text[close.upperBound...])
    }
    if let start = tags.compactMap({ tag -> String.Index? in
      text.range(of: "<\(tag)>", options: .caseInsensitive)?.lowerBound
    }).min() {
      text = String(text[..<start])
    }
    return text
  }

  private static func stripFences(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else {
      return text
    }
    var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    lines.removeFirst()
    if lines.last?.hasPrefix("```") == true {
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }

  private static func jsonValue(in text: String) -> String? {
    if let value = decodeJSON(text) {
      return value
    }
    guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end
    else {
      return nil
    }
    return decodeJSON(String(text[start...end]))
  }

  private static func decodeJSON(_ text: String) -> String? {
    struct Payload: Decodable {
      var value: String?
      var answer: String?
      var result: String?
    }
    guard let data = text.data(using: .utf8),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else {
      return nil
    }
    let value = [payload.value, payload.answer, payload.result]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    return value
  }

  private static func stripDecorations(_ text: String) -> String {
    var line =
      text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { !$0.isEmpty } ?? text
    let prefixes = ["answer:", "result:", "value:", "the answer is"]
    let lowered = line.lowercased()
    if let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) {
      line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
    line = line.replacingOccurrences(of: "**", with: "")
    line = line.replacingOccurrences(of: "__", with: "")
    line = line.replacingOccurrences(of: "`", with: "")
    line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.hasSuffix(".") {
      line.removeLast()
    }
    return line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
  }
}
