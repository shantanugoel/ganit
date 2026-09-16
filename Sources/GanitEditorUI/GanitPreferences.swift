import Foundation

/// App-wide editor preferences. Settings and menus read and write these keys.
public enum GanitPreferences {
  public static let completesWhileTypingKey = "CompletesWhileTyping"

  /// Completes function and keyword names while typing. A fresh copy leaves
  /// this on; Edit ▸ Autocomplete turns it off.
  public static var completesWhileTyping: Bool {
    get {
      UserDefaults.standard.object(forKey: completesWhileTypingKey) as? Bool ?? true
    }
    set {
      UserDefaults.standard.set(newValue, forKey: completesWhileTypingKey)
    }
  }

  public static let hasCompletedTourKey = "HasCompletedTour"

  /// The first-run tour has been skipped or finished. A fresh copy leaves
  /// this off, so the tour is shown once.
  public static var hasCompletedTour: Bool {
    get { UserDefaults.standard.bool(forKey: hasCompletedTourKey) }
    set { UserDefaults.standard.set(newValue, forKey: hasCompletedTourKey) }
  }
}
