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
}
