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
        .library(name: "GanitWorkspaceUI", targets: ["GanitWorkspaceUI"]),
        .library(name: "GanitEditorUI", targets: ["GanitEditorUI"]),
        .library(name: "GanitQuickUI", targets: ["GanitQuickUI"]),
        .library(name: "GanitDocuments", targets: ["GanitDocuments"]),
        .library(name: "GanitData", targets: ["GanitData"]),
        .library(name: "GanitEngine", targets: ["GanitEngine"]),
        .library(name: "GanitFormatting", targets: ["GanitFormatting"]),
        .library(name: "GanitSystemIntegration", targets: ["GanitSystemIntegration"]),
        .library(name: "GanitDiagnostics", targets: ["GanitDiagnostics"])
    ],
    targets: [
        .executableTarget(
            name: "GanitApp",
            dependencies: [
                "GanitWorkspaceUI",
                "GanitQuickUI",
                "GanitSystemIntegration"
            ]
        ),
        .target(
            name: "GanitWorkspaceUI",
            dependencies: [
                "GanitDocuments",
                "GanitEditorUI",
                "GanitFormatting"
            ]
        ),
        .target(
            name: "GanitEditorUI",
            dependencies: [
                "GanitDiagnostics",
                "GanitEngine",
                "GanitFormatting"
            ]
        ),
        .target(
            name: "GanitQuickUI",
            dependencies: [
                "GanitEditorUI",
                "GanitFormatting"
            ]
        ),
        .target(
            name: "GanitDocuments",
            dependencies: ["GanitEngine"]
        ),
        .target(name: "GanitData"),
        .target(name: "GanitEngine"),
        .target(
            name: "GanitFormatting",
            dependencies: [
                "GanitData",
                "GanitEngine"
            ]
        ),
        .target(
            name: "GanitSystemIntegration",
            dependencies: [
                "GanitDocuments",
                "GanitEngine",
                "GanitFormatting"
            ]
        ),
        .target(name: "GanitDiagnostics"),
        .testTarget(
            name: "GanitEngineTests",
            dependencies: ["GanitEngine"]
        ),
        .testTarget(
            name: "GanitWorkspaceUITests",
            dependencies: ["GanitWorkspaceUI"]
        )
    ],
    swiftLanguageModes: [.v6]
)
