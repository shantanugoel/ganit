import Testing

@testable import GanitDiagnostics

@Suite
struct ProblemReportTests {
  @Test
  func describesTheAppAndSystemWithoutSheetTextUnlessIncluded() {
    var report = ProblemReport(
      appVersion: "0.1.0 (1)", systemVersion: "26.6", hardwareModel: "MacBookPro18,2",
      settings: ["Update exchange rates automatically": "On", "Spotlight titles": "Off"],
      sheetCount: 12, reproduction: nil)

    #expect(
      report.text == """
        Ganit problem report

        Describe what you did, what you expected, and what happened:


        App: 0.1.0 (1)
        macOS: 26.6
        Mac: MacBookPro18,2
        Sheets: 12
        Spotlight titles: Off
        Update exchange rates automatically: On

        Reproduction:
        (not included)

        """)

    report.reproduction = "rent = 2,100\nrent * 12"
    #expect(report.text.hasSuffix("Reproduction:\nrent = 2,100\nrent * 12\n"))
    #expect(!ProblemReport.hardwareModelIdentifier.isEmpty)
  }
}
