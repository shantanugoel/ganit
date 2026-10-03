import Foundation
import GanitDocuments
import GanitEngine
import GanitFormatting
import GanitSystemIntegration

/// `ganit`, the command-line calculator. It answers with the same engine,
/// grammar, and formatting as the app:
///
///     ganit '20% off 85'              # one expression → 68
///     ganit 'rent = 3' 'rent * 12'    # each argument is a line
///     ganit < budget.txt              # a sheet → one answer per line
///     ganit --tables < budget.txt     # a sheet → answers plus table grids
///
/// Currency uses the exchange rates the app last accepted; the command never
/// reaches the network.
@main
enum GanitCLI {
  static let usage = """
    usage: ganit LINE...
           ganit < SHEET
           ganit --tables < SHEET

    Answers each argument as one line of a sheet, so a line may declare a name
    that a later one uses, or reads a sheet from standard input. Prints one
    answer per line and exits with status 1 when any line fails.

    With --tables, a sheet's tables are also printed where their source sits,
    as a named grid: failure messages, the header row, the data rows and the
    totals row, tab-separated. Table cells never replace line answers. A
    table with a failure makes the run exit with status 1.

    """

  static func main() {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var structured = false
    if arguments.first == "--tables" {
      structured = true
      arguments.removeFirst()
    }
    if arguments == ["-h"] || arguments == ["--help"] {
      print(usage, terminator: "")
      return
    }
    let calculation = ExpressionCalculation(rates: storedRates())
    guard arguments.isEmpty else {
      do {
        // Each argument is a line, so `ganit 'rent = 3' 'rent * 12'` works.
        let answers = try calculation.answers(forSheet: arguments.joined(separator: "\n"))
        guard answers.count > 1 || answers.first?.isFailure != true else {
          // One expression that failed reports on stderr, for a script.
          fail(answers[0].text ?? usage)
        }
        for answer in answers {
          print(answer.text ?? "")
        }
        if answers.contains(where: \.isFailure) {
          exit(1)
        }
      } catch {
        fail(error.localizedDescription)
      }
      return
    }
    // Read as import reads a file: one leading byte-order mark is not part
    // of the sheet or its limit.
    let input = FileHandle.standardInput.readData(
      ofLength: maximumSheetBytes + SheetExchange.byteOrderMark.count + 1)
    guard let source = SheetExchange.importedSource(input) else {
      fail("The sheet must be UTF-8 text of at most 1 MB.")
    }
    do {
      // Structured mode prints a table's grid where its source sits; scalar
      // mode prints one line per physical line, with empty lines for tables.
      let (answers, tables) = try calculation.structuredAnswers(forSheet: source)
      var tablesAfterLine: [Int: [TableSheetAnswer]] = [:]
      for table in tables {
        tablesAfterLine[table.lastPhysicalLine, default: []].append(table)
      }
      for (index, answer) in answers.enumerated() {
        print(answer.text ?? "")
        if structured, let sheetTables = tablesAfterLine[index] {
          for table in sheetTables {
            printTable(table)
          }
        }
      }
      let tablesFailed = tables.contains { !$0.grid.failures.isEmpty }
      if answers.contains(where: \.isFailure) || (structured && tablesFailed) {
        exit(1)
      }
    } catch {
      fail(error.localizedDescription)
    }
  }

  /// One table's structured output: the display name, then failure
  /// messages, the header row, the data rows and the totals row, separated
  /// by tabs. Values stay display text, without the spreadsheet guard.
  static func printTable(_ table: TableSheetAnswer) {
    if let name = table.grid.name {
      print("Table " + name)
    }
    let text = TableGridText.text(
      table.grid, format: .tsv, locale: Locale.current, guardsFormulas: false)
    print(text, terminator: "")
  }

  /// The engine's source limit, which import also applies.
  static let maximumSheetBytes = SheetExchange.maximumSourceBytes

  /// The last-known-good snapshot in the sandboxed app's container, if the app
  /// has accepted one.
  static func storedRates() -> CurrencyRates {
    let root = FileManager.default.homeDirectoryForCurrentUser.appending(
      path:
        "Library/Containers/com.shantanugoel.Ganit/Data/Library/Application Support/com.shantanugoel.Ganit/ExchangeRates",
      directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: root.path),
      let snapshot = try? RateSnapshotStore(root: root).lastKnownGood()
    else {
      return .none
    }
    return snapshot.currencyRates ?? .none
  }

  static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }
}
