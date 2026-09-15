import Foundation
import Testing

@testable import GanitFormatting

/// The strings a diagnostic is written in ship in a resource bundle, and where
/// that bundle sits depends on how Ganit was assembled. SwiftPM's generated
/// accessor stops the program when it looks in the wrong place, which a
/// sandboxed app always makes it do, so the search is ours and is tested here.
@Suite
struct FormattingResourcesTests {
  private let root = FileManager.default.temporaryDirectory
    .appending(path: "GanitResourceTests-\(UUID().uuidString)", directoryHint: .isDirectory)

  @Test
  func findsTheBundleWhereAnAppKeepsIt() throws {
    let app = root.appending(path: "Ganit.app", directoryHint: .isDirectory)
    let resources = app.appending(path: "Contents/Resources", directoryHint: .isDirectory)
    try makeBundle(in: resources)

    let found = FormattingResources.locate(
      Self.name,
      in: FormattingResources.searchedDirectories(
        from: try #require(Bundle(url: app)),
        and: Bundle.main
      )
    )
    #expect(found?.bundleURL.standardizedFileURL.path == resources.appending(path: Self.name).path)
  }

  /// The command-line tool ships in `Contents/Helpers`, where its own directory
  /// holds no resources and the app's are one level over.
  @Test
  func findsTheBundleFromAHelperBesideIt() throws {
    let contents = root.appending(path: "Ganit.app/Contents", directoryHint: .isDirectory)
    let resources = contents.appending(path: "Resources", directoryHint: .isDirectory)
    let helper = contents.appending(path: "Helpers/ganit")
    try makeBundle(in: resources)
    try FileManager.default.createDirectory(
      at: helper.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: helper)

    let directories = FormattingResources.searchedDirectories(
      from: try #require(Bundle(url: helper.deletingLastPathComponent())),
      and: Bundle.main
    )
    let found = FormattingResources.locate(Self.name, in: directories)
    #expect(found?.bundleURL.standardizedFileURL.path == resources.appending(path: Self.name).path)
  }

  /// A bundle that is nowhere to be found leaves messages as written, rather
  /// than stopping the program the way `Bundle.module` does.
  @Test
  func saysSoWhenThereIsNoBundle() {
    #expect(FormattingResources.locate(Self.name, in: [root]) == nil)
  }

  /// The strings the app runs on are found in the layout it is built into.
  @Test
  func findsTheStringsThisBuildShipsWith() throws {
    let bundle = try #require(FormattingResources.bundle)
    #expect(bundle.path(forResource: "tr", ofType: "lproj") != nil)
  }

  private static let name = "Ganit_GanitFormatting.bundle"

  private func makeBundle(in directory: URL) throws {
    let bundle = directory.appending(path: Self.name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: bundle.appending(path: "Info.plist"))
  }
}
