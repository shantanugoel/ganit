import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut registered with Carbon's hot key service, which
/// works in the App Sandbox without Accessibility or Input Monitoring
/// permission and observes no other keystrokes.
@MainActor
public final class GlobalHotKey {
  private let action: () -> Void
  nonisolated(unsafe) private var hotKey: EventHotKeyRef?
  nonisolated(unsafe) private var handler: EventHandlerRef?

  public private(set) var shortcut: KeyboardShortcut?

  public init(action: @escaping () -> Void) {
    self.action = action
  }

  deinit {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
    }
    if let handler {
      RemoveEventHandler(handler)
    }
  }

  /// Registers a shortcut in place of any previous one. Throws
  /// `ShortcutConflict.otherApplication` when another app holds it.
  public func register(_ shortcut: KeyboardShortcut) throws {
    unregister()
    try installHandler()
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      shortcut.keyCode,
      shortcut.carbonModifiers,
      EventHotKeyID(signature: OSType(0x4741_4E54), id: 1),
      GetApplicationEventTarget(),
      0,
      &reference
    )
    guard status == noErr else {
      throw ShortcutRegistrationError(conflict: .otherApplication, status: status)
    }
    hotKey = reference
    self.shortcut = shortcut
  }

  public func unregister() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
    }
    hotKey = nil
    shortcut = nil
  }

  private func installHandler() throws {
    guard handler == nil else {
      return
    }
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context else {
          return OSStatus(eventNotHandledErr)
        }
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { hotKey.action() }
        return noErr
      },
      1,
      &type,
      Unmanaged.passUnretained(self).toOpaque(),
      &handler
    )
    guard status == noErr else {
      throw ShortcutRegistrationError(conflict: nil, status: status)
    }
  }
}

public struct ShortcutRegistrationError: Error, Equatable {
  public let conflict: ShortcutConflict?
  public let status: OSStatus
}
