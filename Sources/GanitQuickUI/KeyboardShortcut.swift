import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a physical key with at least one modifier.
public struct KeyboardShortcut: Codable, Equatable, Sendable {
  public static let modifierMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
  /// Suggested only after its conflicts are shown; never enabled by default.
  public static let suggested = KeyboardShortcut(
    keyCode: UInt32(kVK_Space), modifiers: [.option], key: "Space")

  public let keyCode: UInt32
  private let modifierFlags: UInt
  /// The key's name when recorded, such as `Space` or `K`.
  public let key: String

  public var modifiers: NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: modifierFlags).intersection(Self.modifierMask)
  }

  public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, key: String) {
    self.keyCode = keyCode
    modifierFlags = modifiers.intersection(Self.modifierMask).rawValue
    self.key = key
  }

  /// A shortcut recorded from a key event, or `nil` without a modifier.
  public init?(event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(Self.modifierMask)
    guard event.type == .keyDown, !modifiers.isEmpty else {
      return nil
    }
    let key: String =
      switch Int(event.keyCode) {
      case kVK_Space: "Space"
      case kVK_Return: "↩"
      case kVK_Tab: "⇥"
      case kVK_Delete: "⌫"
      case kVK_Escape: "⎋"
      case kVK_LeftArrow: "←"
      case kVK_RightArrow: "→"
      case kVK_UpArrow: "↑"
      case kVK_DownArrow: "↓"
      default: event.charactersIgnoringModifiers?.uppercased() ?? "?"
      }
    self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: key)
  }

  /// The shortcut in standard modifier order, such as `⌥Space`.
  public var displayName: String {
    [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
      .filter { modifiers.contains($0.0) }
      .map(\.1)
      .joined() + key
  }

  /// The modifiers as Carbon event modifiers.
  var carbonModifiers: UInt32 {
    [
      (NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey), (.control, controlKey),
      (.shift, shiftKey),
    ]
    .filter { modifiers.contains($0.0) }
    .reduce(0) { $0 | UInt32($1.1) }
  }
}

/// A reason a shortcut may not work as expected.
public enum ShortcutConflict: Equatable, Sendable {
  /// An enabled macOS shortcut, such as Spotlight or input-source switching.
  case system
  /// A command in Ganit's own menus.
  case menu(title: String)
  /// Another app has already registered it.
  case otherApplication
}

extension KeyboardShortcut {
  /// Known conflicts with enabled system shortcuts and the given menu.
  public func conflicts(in menu: NSMenu?) -> [ShortcutConflict] {
    var conflicts: [ShortcutConflict] = []
    if Self.enabledSystemShortcuts().contains(where: {
      $0.keyCode == keyCode && $0.modifiers == carbonModifiers
    }) {
      conflicts.append(.system)
    }
    if let title = menu.flatMap(menuItemTitle) {
      conflicts.append(.menu(title: title))
    }
    return conflicts
  }

  private func menuItemTitle(in menu: NSMenu) -> String? {
    for item in menu.items {
      if let title = item.submenu.flatMap(menuItemTitle) {
        return title
      }
      guard !item.keyEquivalent.isEmpty,
        item.keyEquivalentModifierMask.intersection(Self.modifierMask) == modifiers
      else {
        continue
      }
      let key = item.keyEquivalent == " " ? "Space" : item.keyEquivalent.uppercased()
      if key == self.key {
        return item.title
      }
    }
    return nil
  }

  /// Enabled system-wide symbolic hot keys as key codes with Carbon modifiers.
  static func enabledSystemShortcuts() -> [(keyCode: UInt32, modifiers: UInt32)] {
    var unmanaged: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&unmanaged) == noErr,
      let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]]
    else {
      return []
    }
    return hotKeys.compactMap { hotKey in
      guard hotKey[kHISymbolicHotKeyEnabled] as? Bool == true,
        let code = hotKey[kHISymbolicHotKeyCode] as? Int,
        let modifiers = hotKey[kHISymbolicHotKeyModifiers] as? Int
      else {
        return nil
      }
      let relevant = UInt32(modifiers) & UInt32(cmdKey | optionKey | controlKey | shiftKey)
      return (UInt32(code), relevant)
    }
  }
}
