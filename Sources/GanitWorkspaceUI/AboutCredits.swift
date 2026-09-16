import AppKit
import GanitEditorUI

/// Credits shown in the About panel: who made Ganit, and where to find it.
public enum AboutCredits {
  public static let author = "Shantanu Goel"
  public static let xHandle = "shantanugoel"
  public static let xURL = URL(string: "https://x.com/shantanugoel")!
  public static let repositoryURL = URL(string: "https://github.com/shantanugoel/ganit")!

  public static func attributedString() -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = VisualStyle.Spacing.tight
    let base: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: VisualStyle.Color.primary,
      .paragraphStyle: paragraph,
    ]
    let credits = NSMutableAttributedString()
    credits.append(NSAttributedString(string: "\(author)\n", attributes: base))
    var x = base
    x[.link] = xURL
    credits.append(NSAttributedString(string: "x.com/\(xHandle)\n", attributes: x))
    var github = base
    github[.link] = repositoryURL
    credits.append(
      NSAttributedString(string: "github.com/shantanugoel/ganit", attributes: github))
    return credits
  }
}
