import Foundation

/// Where this module's strings live.
///
/// A package build leaves the resource bundle beside the executable, an app
/// keeps it in `Contents/Resources`, and a helper inside an app runs from
/// `Contents/Helpers` beside that. SwiftPM's generated `Bundle.module` knows
/// only the first and the absolute path of the machine that built it, and stops
/// the program when it finds neither, so a sandboxed app cannot use it: the
/// build directory is outside the container.
///
/// Wording an answer is not worth stopping for, so a bundle that cannot be
/// found leaves each message as the English written at its call site.
enum FormattingResources {
  static let bundle = locate(
    "Ganit_GanitFormatting.bundle",
    in: searchedDirectories(from: Bundle.main, and: Bundle(for: Marker.self))
  )

  /// The directories a resource bundle sits in, nearest first: an app's
  /// resources, a package build's product directory, the resources a helper
  /// such as the command-line tool sits beside, and, when this module is linked
  /// into a bundle of its own such as the test bundle, the directory that
  /// bundle was built into.
  static func searchedDirectories(from main: Bundle, and module: Bundle) -> [URL] {
    [
      main.resourceURL,
      main.bundleURL,
      main.bundleURL.deletingLastPathComponent()
        .appending(path: "Resources", directoryHint: .isDirectory),
      module.resourceURL,
      module.bundleURL,
      module.bundleURL.deletingLastPathComponent(),
    ].compactMap { $0 }
  }

  static func locate(_ name: String, in directories: [URL]) -> Bundle? {
    for directory in directories {
      if let bundle = Bundle(url: directory.appending(path: name)) {
        return bundle
      }
    }
    return nil
  }

  /// Finds the bundle of the framework holding this module, when there is one.
  private final class Marker {}
}
