#!/usr/bin/env swift
import AppKit
import Foundation

/// Renders the menu bar `function` mark into an .icns for the app bundle.
_ = NSApplication.shared

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: generate-app-icon.swift AppIcon.icns\n".utf8))
  exit(64)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let work = FileManager.default.temporaryDirectory.appending(path: "GanitAppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func png(size: Int, named name: String) throws {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  let bounds = NSRect(x: 0, y: 0, width: size, height: size)
  NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
  NSBezierPath(roundedRect: bounds, xRadius: CGFloat(size) * 0.22, yRadius: CGFloat(size) * 0.22)
    .fill()
  let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.5, weight: .medium)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
  if let symbol = NSImage(systemSymbolName: "function", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration)
  {
    let symbolSize = symbol.size
    symbol.draw(
      in: NSRect(
        x: (CGFloat(size) - symbolSize.width) / 2,
        y: (CGFloat(size) - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
      ),
      from: .zero,
      operation: .sourceOver,
      fraction: 1
    )
  }
  image.unlockFocus()
  guard let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let data = bitmap.representation(using: .png, properties: [:])
  else {
    throw CocoaError(.fileWriteUnknown)
  }
  try data.write(to: work.appending(path: name))
}

try png(size: 16, named: "icon_16x16.png")
try png(size: 32, named: "icon_16x16@2x.png")
try png(size: 32, named: "icon_32x32.png")
try png(size: 64, named: "icon_32x32@2x.png")
try png(size: 128, named: "icon_128x128.png")
try png(size: 256, named: "icon_128x128@2x.png")
try png(size: 256, named: "icon_256x256.png")
try png(size: 512, named: "icon_256x256@2x.png")
try png(size: 512, named: "icon_512x512.png")
try png(size: 1024, named: "icon_512x512@2x.png")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", destination.path, work.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
  exit(process.terminationStatus)
}
