import Foundation
import GanitEngine

/// One table's grid as text a reader sees: the name, headers, cell display
/// text, totals and whole-table failures. Exports and headless readers show
/// the same text the editor shows, so a value is never rounded twice.
public struct TableGrid: Equatable, Sendable {
  /// The table's display name, or `nil` for a block Ganit cannot read.
  public let name: String?
  public let headers: [String]
  /// One row of display text per data row, in grid order.
  public let rows: [[String]]
  /// One entry per column: the formatted totals footer, or `nil` when that
  /// column has no total. Empty when no column has one.
  public let totals: [String?]
  /// Whole-table problems: block diagnostics, then a calculation failure,
  /// in order. Empty for a calculated table.
  public let failures: [String]

  public init(
    name: String?, headers: [String], rows: [[String]], totals: [String?], failures: [String]
  ) {
    self.name = name
    self.headers = headers
    self.rows = rows
    self.totals = totals
    self.failures = failures
  }
}

/// How a table export separates fields.
public enum TableTextFormat: String, Sendable {
  /// Tab-separated fields, as the editor copies them.
  case tsv
  /// Comma-separated text per RFC 4180, with CRLF row endings.
  case csv
}

/// Builds a table's display grid and writes it as tab- or comma-separated
/// text.
public enum TableGridText {
  /// The grid of one table result: the display text the editor shows, with
  /// each failed cell's message. A block Ganit cannot read has no columns
  /// and reports its diagnostics in `failures`.
  public static func grid(
    _ snapshot: TableResultSnapshot, formatter: ResultFormatter,
    diagnostics: DiagnosticFormatter, pending: String = "Pending…"
  ) -> TableGrid {
    let columns = snapshot.columns
    let rows = snapshot.rows.map { row in
      columns.map { column in
        cellText(
          snapshot.value(row: row, column: column.id), snapshot: snapshot, row: row,
          column: column, formatter: formatter, diagnostics: diagnostics, pending: pending)
      }
    }
    let totals = columns.map { column -> String? in
      guard let total = column.total else { return nil }
      let rectangle = TableCellRectangle(
        rows: 0..<snapshot.rows.count,
        columns: snapshot.columns.firstIndex(of: column).map { $0..<($0 + 1) } ?? 0..<0)
      return snapshot.aggregate(total, rectangle: rectangle)
        .map { (try? formatter.format($0))?.display ?? localizedError } ?? localizedError
    }
    let failures =
      snapshot.diagnostics.map { diagnostics.format($0).message }
      + (snapshot.calculationFailure.map { [diagnostics.format($0).message] } ?? [])
    let hasTotals = totals.contains(where: { $0 != nil })
    return TableGrid(
      name: snapshot.name,
      headers: columns.map(\.header),
      rows: rows,
      totals: hasTotals ? totals : [],
      failures: failures
    )
  }

  /// The separator CSV uses for `locale`: a semicolon where the decimal
  /// separator is a comma, so `1,50` never splits in two.
  public static func csvSeparator(for locale: Locale) -> String {
    locale.decimalSeparator == "," ? ";" : ","
  }

  /// One field made safe for a spreadsheet: a leading apostrophe when
  /// another app would run the text as a formula, then quoting when the
  /// field holds the separator, a quote, or a line break.
  public static func field(_ text: String, format: TableTextFormat, locale: Locale) -> String {
    let separator = format == .csv ? csvSeparator(for: locale) : "\t"
    return field(text, separator: separator)
  }

  static func field(_ text: String, separator: String) -> String {
    let guarded =
      text.first.map(Self.formulaStarts.contains) == true && Double(text) == nil
      ? "'" + text : text
    let quoted = separator != "\t" ? separator : ""
    let splitters = "\n\r\"" + separator + quoted
    guard guarded.contains(where: { splitters.contains($0) }) else {
      return guarded
    }
    return "\"" + guarded.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// Characters that start a formula in common spreadsheets, plus the
  /// separators that paste as leading characters.
  static let formulaStarts: Set<Character> = ["=", "+", "-", "@", "\t", "\r"]

  /// Writes one table as text: failure lines, the header row, the data rows
  /// and the totals footer. CSV quotes per RFC 4180 and ends rows with CRLF;
  /// TSV ends rows with LF, as copy and paste do.
  public static func text(
    _ grid: TableGrid, format: TableTextFormat, includesHeader: Bool = true, locale: Locale
  ) -> String {
    let separator = format == .csv ? csvSeparator(for: locale) : "\t"
    var lines = grid.failures.map { field($0, separator: separator) }
    if includesHeader, !grid.headers.isEmpty {
      lines.append(cells(grid.headers, format: format, separator: separator))
    }
    lines += grid.rows.map { cells($0, format: format, separator: separator) }
    if grid.totals.contains(where: { $0 != nil }) {
      lines.append(cells(grid.totals.map { $0 ?? "" }, format: format, separator: separator))
    }
    return lines.map { $0 + (format == .csv ? "\r\n" : "\n") }.joined()
  }

  static func cells(_ values: [String], format: TableTextFormat, separator: String) -> String {
    values.map { field($0, separator: separator) }.joined(separator: separator)
  }

  private static func cellText(
    _ value: TableCellValue?, snapshot: TableResultSnapshot, row: RowID,
    column: TableResultColumn, formatter: ResultFormatter, diagnostics: DiagnosticFormatter,
    pending: String
  ) -> String {
    switch value {
    case .value(let scalar):
      return (try? formatter.format(scalar))?.display ?? ""
    case .text(let text): return text
    case .blank: return ""
    case .failure:
      if let error = snapshot.cellError(row: row, column: column.id) {
        return diagnostics.format(error).message
      }
      return localizedError
    case nil:
      if let failure = snapshot.calculationFailure {
        return diagnostics.format(failure).message
      }
      return pending
    }
  }

  private static func localized(_ key: StaticString, defaultValue: String.LocalizationValue)
    -> String
  {
    String(localized: key, defaultValue: defaultValue, bundle: FormattingResources.bundle)
  }

  private static var localizedError: String {
    localized("table.export.error", defaultValue: "Error")
  }
}
