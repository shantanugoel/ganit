import Foundation
import Testing

@testable import GanitEngine

@Test
func engineModuleLoadsWithoutApplicationFrameworks() {
  // Importing this target independently verifies the Phase 0 package boundary.
}

@Test
func engineSourcesDoNotImportUIFrameworks() throws {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let engineDirectory = repositoryRoot.appending(path: "Sources/GanitEngine")
  let sourceURLs = try #require(
    FileManager.default.enumerator(
      at: engineDirectory,
      includingPropertiesForKeys: nil
    )?.compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
  )

  for sourceURL in sourceURLs {
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    #expect(!source.contains("import AppKit"))
    #expect(!source.contains("import SwiftUI"))
  }
}

@Test
func applicationModulesDoNotImportBigIntDirectly() throws {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let sourcesDirectory = repositoryRoot.appending(path: "Sources")
  let sourceURLs = try #require(
    FileManager.default.enumerator(
      at: sourcesDirectory,
      includingPropertiesForKeys: nil
    )?.compactMap { $0 as? URL }
      .filter {
        $0.pathExtension == "swift"
          && !$0.path.contains("/Sources/GanitEngine/")
      }
  )

  for sourceURL in sourceURLs {
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    #expect(!source.contains("import BigInt"))
  }
}

/// App modules never log, so no expression, sheet text, or title can reach
/// the system log. Command-line and benchmark tools print their own output.
@Test
func appModulesDoNotLog() throws {
  let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources")
  let tools: Set<String> = [
    "GanitCLI", "GanitBenchmarks", "GanitEngineHarness", "GanitUnitAttributionGenerator",
  ]
  for module in try FileManager.default.contentsOfDirectory(atPath: sources.path)
  where !tools.contains(module) && !module.hasPrefix(".") {
    let files = try #require(
      FileManager.default.enumerator(
        at: sources.appending(path: module), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
    for file in files {
      let source = try String(contentsOf: file, encoding: .utf8)
      for call in ["print(", "NSLog(", "os_log(", "Logger(", "debugPrint(", "dump("] {
        #expect(!source.contains(call), "\(module)/\(file.lastPathComponent) calls \(call)")
      }
    }
  }
}

/// `Bundle.module` stops the program when it cannot find its resource bundle,
/// and it looks only beside the executable and in the absolute build directory
/// of the machine that compiled it. A sandboxed app reaches neither, so a use of
/// it crashes the shipped app the first time it needs a word. `Sources` find
/// their strings through `FormattingResources` instead.
@Test
func sourcesFindStringsWithoutTrappingOnAMissingBundle() throws {
  let sources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Sources")
  let files = try #require(
    FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" })
  // The file that replaces it is where the reason is written down.
  for file in files where file.lastPathComponent != "FormattingResources.swift" {
    let source = try String(contentsOf: file, encoding: .utf8)
    #expect(!source.contains("Bundle.module"), "\(file.lastPathComponent) uses Bundle.module")
    #expect(!source.contains("bundle: .module"), "\(file.lastPathComponent) uses Bundle.module")
  }
}
