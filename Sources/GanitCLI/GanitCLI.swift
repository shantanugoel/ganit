import Foundation
import GanitDocuments
import GanitEngine
import GanitSystemIntegration

/// `ganit`, the command-line calculator. It answers with the same engine,
/// grammar, and formatting as the app:
///
///     ganit '20% off 85'        # one expression → 68
///     ganit < budget.txt        # a sheet → one answer per line
///
/// Currency uses the exchange rates the app last accepted; the command never
/// reaches the network.
@main
enum GanitCLI {
  static let usage = """
    usage: ganit EXPRESSION...
           ganit < SHEET

    Answers one expression, or reads a sheet from standard input and prints
    one answer per line. Exits with status 1 when any line fails.

    """

  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["-h"] || arguments == ["--help"] {
      print(usage, terminator: "")
      return
    }
    let calculation = ExpressionCalculation(rates: storedRates())
    guard arguments.isEmpty else {
      do {
        print(try calculation.answer(for: arguments.joined(separator: " ")))
      } catch {
        fail(error.localizedDescription)
      }
      return
    }
    let input = FileHandle.standardInput.readData(ofLength: maximumSheetBytes + 1)
    guard input.count <= maximumSheetBytes, let source = String(data: input, encoding: .utf8)
    else {
      fail("The sheet must be UTF-8 text of at most 1 MB.")
    }
    do {
      let answers = try calculation.answers(forSheet: source)
      for answer in answers.dropLast(source.hasSuffix("\n") ? 1 : 0) {
        print(answer.text ?? "")
      }
      if answers.contains(where: \.isFailure) {
        exit(1)
      }
    } catch {
      fail(error.localizedDescription)
    }
  }

  /// The engine's source limit.
  static let maximumSheetBytes = 1_048_576

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
