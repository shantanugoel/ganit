import Foundation

extension DocumentStorageError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion(let version):
      String(
        format: localized(
          "storage.unsupportedSchema",
          "This sheet was saved in format %lld, which this version of Ganit can't open."),
        version)
    case .invalidUTF8:
      localized(
        "storage.invalidUTF8", "This sheet's text isn't valid UTF-8, so Ganit can't open it.")
    case .posix, .undeletableSheet:
      nil
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .unsupportedSchemaVersion, .invalidUTF8:
      localized("storage.leftUnchanged", "The file was left unchanged.")
    case .posix, .undeletableSheet:
      nil
    }
  }
}

extension SheetExchangeError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .unsupportedSchemaVersion(let version):
      String(
        format: localized(
          "exchange.unsupportedSchema",
          "This Ganit sheet was saved in format %lld, which this version of Ganit can't open."),
        version)
    case .invalidUTF8(let url):
      String(
        format: localized("exchange.invalidUTF8", "“%@” isn't UTF-8 text, so Ganit can't open it."),
        url.lastPathComponent)
    case .tooLarge(let url):
      String(
        format: localized("exchange.tooLarge", "“%@” is larger than a Ganit sheet can be."),
        url.lastPathComponent)
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .unsupportedSchemaVersion, .invalidUTF8:
      localized("storage.leftUnchanged", "The file was left unchanged.")
    case .tooLarge:
      nil
    }
  }
}

/// A string from the app's catalog, so messages shown by the app are
/// localized with the rest of its interface.
func localized(_ key: StaticString, _ defaultValue: String.LocalizationValue) -> String {
  String(localized: key, defaultValue: defaultValue, bundle: .main)
}
