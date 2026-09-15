import Foundation
import GanitEngine

do {
  let catalog = try UnitCatalog.minimal()
  FileHandle.standardOutput.write(Data(catalog.attributionMarkdown.utf8))
} catch {
  FileHandle.standardError.write(
    Data("Unable to generate unit attribution: \(error)\n".utf8)
  )
  exit(EX_SOFTWARE)
}
