/// A completion's source spelling and an optional preview of its value.
struct CompletionItem: Equatable {
  let insertion: String
  let detail: String

  init(_ insertion: String, detail: String = "") {
    self.insertion = insertion
    self.detail = detail
  }
}
