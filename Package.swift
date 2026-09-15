// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "Ganit",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "GanitApp", targets: ["GanitApp"]),
    .executable(name: "GanitBenchmarks", targets: ["GanitBenchmarks"]),
    .executable(name: "ganit", targets: ["GanitCLI"]),
    .library(name: "GanitWorkspaceUI", targets: ["GanitWorkspaceUI"]),
    .library(name: "GanitEditorUI", targets: ["GanitEditorUI"]),
    .library(name: "GanitQuickUI", targets: ["GanitQuickUI"]),
    .library(name: "GanitDocuments", targets: ["GanitDocuments"]),
    .library(name: "GanitData", targets: ["GanitData"]),
    .library(name: "GanitEngine", targets: ["GanitEngine"]),
    .library(name: "GanitFormatting", targets: ["GanitFormatting"]),
    .library(name: "GanitSystemIntegration", targets: ["GanitSystemIntegration"]),
    .library(name: "GanitDiagnostics", targets: ["GanitDiagnostics"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/attaswift/BigInt.git",
      exact: "6.0.1"
    )
  ],
  targets: [
    .executableTarget(
      name: "GanitApp",
      dependencies: [
        "GanitDiagnostics",
        "GanitDocuments",
        "GanitWorkspaceUI",
        "GanitQuickUI",
        "GanitSystemIntegration",
      ]
    ),
    .target(
      name: "GanitWorkspaceUI",
      dependencies: [
        "GanitDocuments",
        "GanitEditorUI",
        "GanitEngine",
        "GanitFormatting",
      ]
    ),
    .target(
      name: "GanitEditorUI",
      dependencies: [
        "GanitDiagnostics",
        "GanitEngine",
        "GanitFormatting",
      ]
    ),
    .target(
      name: "GanitQuickUI",
      dependencies: [
        "GanitDocuments",
        "GanitEditorUI",
        "GanitEngine",
      ]
    ),
    .target(
      name: "GanitDocuments",
      dependencies: ["GanitData", "GanitEngine"]
    ),
    .target(name: "GanitData"),
    .target(
      name: "GanitEngine",
      dependencies: [
        .product(name: "BigInt", package: "BigInt")
      ]
    ),
    .target(
      name: "GanitFormatting",
      dependencies: [
        "GanitData",
        "GanitEngine",
      ],
      resources: [.process("Resources")]
    ),
    .target(
      name: "GanitSystemIntegration",
      dependencies: [
        "GanitDocuments",
        "GanitEngine",
        "GanitFormatting",
      ]
    ),
    .target(name: "GanitDiagnostics"),
    .executableTarget(
      name: "GanitBenchmarks",
      dependencies: ["GanitEditorUI", "GanitEngine", "GanitQuickUI"]
    ),
    .executableTarget(
      name: "GanitCLI",
      dependencies: ["GanitDocuments", "GanitEngine", "GanitSystemIntegration"]
    ),
    .executableTarget(
      name: "GanitEngineHarness",
      dependencies: [
        "GanitEngine",
        "GanitFormatting",
      ]
    ),
    .executableTarget(
      name: "GanitUnitAttributionGenerator",
      dependencies: ["GanitEngine"]
    ),
    .testTarget(
      name: "GanitEngineTests",
      dependencies: ["GanitEngine"]
    ),
    .testTarget(
      name: "GanitFormattingTests",
      dependencies: ["GanitFormatting"]
    ),
    .testTarget(
      name: "GanitEngineCorpusTests",
      dependencies: [
        "GanitEngine",
        "GanitFormatting",
      ],
      resources: [.process("Fixtures")]
    ),
    .executableTarget(
      name: "GanitStorageStressHelper",
      dependencies: ["GanitDocuments"],
      path: "Tests/GanitStorageStressHelper"
    ),
    .testTarget(
      name: "GanitDiagnosticsTests",
      dependencies: ["GanitDiagnostics"]
    ),
    .testTarget(
      name: "GanitDataTests",
      dependencies: ["GanitData"]
    ),
    .testTarget(
      name: "GanitDocumentsTests",
      dependencies: ["GanitData", "GanitDocuments", "GanitEngine", "GanitStorageStressHelper"]
    ),
    .testTarget(
      name: "GanitEditorUITests",
      dependencies: ["GanitEditorUI", "GanitEngine"]
    ),
    .testTarget(
      name: "GanitQuickUITests",
      dependencies: ["GanitEditorUI", "GanitEngine", "GanitQuickUI"]
    ),
    .testTarget(
      name: "GanitSystemIntegrationTests",
      dependencies: ["GanitEngine", "GanitSystemIntegration"]
    ),
    .testTarget(
      name: "GanitWorkspaceUITests",
      dependencies: ["GanitDocuments", "GanitEngine", "GanitQuickUI", "GanitWorkspaceUI"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
