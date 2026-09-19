import Foundation
import Testing

@testable import GanitDocuments

@MainActor
@Suite
struct AssistantAnswerStoreTests {
  private let url = FileManager.default.temporaryDirectory
    .appending(path: "GanitAssistantAnswers-\(UUID().uuidString).json")

  @Test
  func keepsRepliesAcrossLaunchesUntilForgotten() throws {
    let store = AssistantAnswerStore(url: url)
    #expect(store.answer(to: "10 kg of water in ml") == nil)
    store.record("10000 ml", for: "10 kg of water in ml")
    store.record(nil, for: "the meaning of life")

    let reopened = AssistantAnswerStore(url: url)
    #expect(reopened.answer(to: "10 kg of water in ml") == .some("10000 ml"))
    // The model had no answer, which is kept too, so it is not asked again.
    #expect(reopened.answer(to: "the meaning of life") == .some(nil))

    reopened.forget("10 kg of water in ml")
    #expect(AssistantAnswerStore(url: url).answer(to: "10 kg of water in ml") == nil)
    try? FileManager.default.removeItem(at: url)
  }
}
