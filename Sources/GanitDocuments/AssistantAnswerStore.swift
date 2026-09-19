import Foundation

/// The assistant's replies, by the text asked, kept across launches so that
/// reopening a sheet does not ask again. Only Ask Assistant asks anew. An
/// empty reply records that the model had no answer.
@MainActor
public final class AssistantAnswerStore {
  private let url: URL
  private var answers: [String: String]

  public init(url: URL) {
    self.url = url
    answers =
      (try? Data(contentsOf: url)).flatMap {
        try? JSONDecoder().decode([String: String].self, from: $0)
      } ?? [:]
  }

  public static func applicationSupport() throws -> AssistantAnswerStore {
    AssistantAnswerStore(
      url: try SheetLibrary.applicationSupportRoot().appending(path: "AssistantAnswers.json"))
  }

  /// The recorded reply, `.some(nil)` when the model had none, or `nil` when
  /// the text was never asked.
  public func answer(to asked: String) -> String?? {
    answers[asked].map { $0.isEmpty ? nil : $0 }
  }

  public func record(_ answer: String?, for asked: String) {
    answers[asked] = answer ?? ""
    save()
  }

  public func forget(_ asked: String) {
    if answers.removeValue(forKey: asked) != nil {
      save()
    }
  }

  private func save() {
    if let data = try? JSONEncoder().encode(answers) {
      try? AtomicFile.write(data, to: url)
    }
  }
}
