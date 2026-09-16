import AppKit
import Testing

@testable import GanitWorkspaceUI

@MainActor
@Suite
struct AboutCreditsTests {
  @Test
  func namesTheAuthorAndLinks() {
    let credits = AboutCredits.attributedString()
    let text = credits.string
    #expect(text.contains("Shantanu Goel"))
    #expect(text.contains("shantanugoel"))
    #expect(text.contains("github.com/shantanugoel/ganit"))
    #expect(AboutCredits.xURL.absoluteString == "https://x.com/shantanugoel")
    #expect(AboutCredits.repositoryURL.absoluteString == "https://github.com/shantanugoel/ganit")

    var foundX = false
    var foundGitHub = false
    credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) {
      value, _, _ in
      guard let url = value as? URL else {
        return
      }
      if url == AboutCredits.xURL {
        foundX = true
      }
      if url == AboutCredits.repositoryURL {
        foundGitHub = true
      }
    }
    #expect(foundX)
    #expect(foundGitHub)
  }
}
