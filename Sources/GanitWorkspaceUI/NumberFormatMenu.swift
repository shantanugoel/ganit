import AppKit
import GanitEditorUI
import GanitEngine
import GanitFormatting

extension MainMenu {
  /// The sheet-wide number formats, in `NumberFormatMenu.displays` order.
  static func numberFormatItems() -> [NSMenuItem] {
    NumberFormatMenu.displays.map { display in
      let item = NSMenuItem(
        title: NumberFormatMenu.title(of: display),
        action: #selector(WorkspaceCommands.setNumberFormat(_:)),
        keyEquivalent: ""
      )
      item.tag = NumberFormatMenu.tag(of: display)
      return item
    }
  }

  /// The dollar currencies `$` can mean on a sheet.
  static func dollarCurrencyItems() -> [NSMenuItem] {
    CurrencyCatalog.dollarCurrencies.map { code in
      let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
      let item = NSMenuItem(
        title: "\(code) — \(name)",
        action: #selector(WorkspaceCommands.setDollarCurrency(_:)),
        keyEquivalent: ""
      )
      item.representedObject = code
      return item
    }
  }
}
