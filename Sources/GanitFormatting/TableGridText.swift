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
  /// True when at least one cell failed to calculate. A table that cannot
  /// be read has no cells and reports its problems in `failures`.
  public let hasFailedCells: Bool

  public init(
    name: String?, headers: [String], rows: [[String]], totals: [String?], failures: [String],
    hasFailedCells: Bool = false
  ) {
    self.name = name
    self.headers = headers
    self.rows = rows
    self.totals = totals
    self.failures = failures
    self.hasFailedCells = hasFailedCells
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
    var hasFailedCells = false
    let rows = snapshot.rows.map { row -> [String] in
      columns.map { column -> String in
        let value = snapshot.value(row: row, column: column.id)
        if case .failure? = value {
          hasFailedCells = true
        }
        return cellText(
          value, snapshot: snapshot, row: row,
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
      failures: failures,
      hasFailedCells: hasFailedCells
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
    return field(text, separator: separator, locale: locale)
  }

  static func field(
    _ text: String, separator: String, locale: Locale, guardsFormulas: Bool = true
  ) -> String {
    let guarded =
      guardsFormulas && startsLikeFormula(text, locale: locale)
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

  /// True when `text` reads as a plain number for `locale`: the locale's
  /// minus sign, grouping separators and decimal separator around digits,
  /// with nothing else. `-2,100` in an English locale and `-1,5` in a
  /// German one are numbers, not formulas, so exports leave them alone.
  public static func isPlainNumberDisplay(_ text: String, locale: Locale) -> Bool {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    return formatter.number(from: text) != nil
  }

  /// Writes one table as text: failure lines, the header row, the data rows
  /// and the totals footer. CSV quotes per RFC 4180 and ends rows with CRLF;
  /// TSV ends rows with LF, as copy and paste do. `guardsFormulas` controls
  /// the leading-apostrophe treatment: exports for other apps keep it, and
  /// machine-readable output turns it off so values read unchanged.
  public static func text(
    _ grid: TableGrid, format: TableTextFormat, includesHeader: Bool = true, locale: Locale,
    guardsFormulas: Bool = true
  ) -> String {
    let separator = format == .csv ? csvSeparator(for: locale) : "\t"
    var lines = grid.failures.map {
      field($0, separator: separator, locale: locale, guardsFormulas: guardsFormulas)
    }
    if includesHeader, !grid.headers.isEmpty {
      lines.append(
        cells(grid.headers, separator: separator, guardsFormulas: guardsFormulas, locale: locale))
    }
    lines += grid.rows.map {
      cells($0, separator: separator, guardsFormulas: guardsFormulas, locale: locale)
    }
    if grid.totals.contains(where: { $0 != nil }) {
      lines.append(
        cells(
          grid.totals.map { $0 ?? "" }, separator: separator, guardsFormulas: guardsFormulas,
          locale: locale))
    }
    return lines.map { $0 + (format == .csv ? "\r\n" : "\n") }.joined()
  }

  /// Would a spreadsheet run `text` as a formula: it starts with a formula
  /// character and is neither a canonical number nor a number written the
  /// way this locale displays them. `-2,100` in an English locale and
  /// `-1,5` in a German one are numbers, not formulas.
  public static func startsLikeFormula(_ text: String, locale: Locale) -> Bool {
    guard text.first.map(Self.formulaStarts.contains) == true, Double(text) == nil else {
      return false
    }
    return !isPlainNumberDisplay(text, locale: locale)
  }

  static func cells(
    _ values: [String], separator: String, guardsFormulas: Bool, locale: Locale
  ) -> String {
    values.map { field($0, separator: separator, locale: locale, guardsFormulas: guardsFormulas) }
      .joined(separator: separator)
  }

  private static func cellText(
    _ value: TableCellValue?, snapshot: TableResultSnapshot, row: RowID,
    column: TableResultColumn, formatter: ResultFormatter, diagnostics: DiagnosticFormatter,
    pending: String
  ) -> String {
    switch value {
    case .value(let scalar):
      return (try? formatter.formatTable(scalar, snapshot: snapshot, column: column.id))?.display
        ?? ""
    case .text(let text): return text
    case .blank: return ""
    case .failure:
      if let problem = snapshot.cellProblem(row: row, column: column.id) { return problem }
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
