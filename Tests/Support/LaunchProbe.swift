import CoreGraphics
import Darwin
import Foundation

private enum ProbeError: Error, CustomStringConvertible {
  case invalidArguments
  case windowTimeout(sample: Int)

  var description: String {
    switch self {
    case .invalidArguments:
      return "usage: LaunchProbe <application-executable> <sample-count>"
    case .windowTimeout(let sample):
      return "sample \(sample): no visible layer-zero window appeared within 5 seconds"
    }
  }
}

private func hasVisibleWindow(processIdentifier: pid_t) -> Bool {
  guard
    let windowList = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      .zero
    ) as? [[String: Any]]
  else {
    return false
  }

  return windowList.contains { window in
    (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier
      && (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
  }
}

private func milliseconds(_ duration: Duration) -> Double {
  let components = duration.components
  return Double(components.seconds) * 1_000
    + Double(components.attoseconds) / 1_000_000_000_000_000
}

private func percentile(_ sortedValues: [Double], _ percentile: Double) -> Double {
  let rank = max(1, Int(ceil(percentile * Double(sortedValues.count))))
  return sortedValues[rank - 1]
}

do {
  guard
    CommandLine.arguments.count == 3,
    let sampleCount = Int(CommandLine.arguments[2]),
    sampleCount > 0
  else {
    throw ProbeError.invalidArguments
  }

  let executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
  let clock = ContinuousClock()
  var samples: [Double] = []

  for sampleIndex in 1...sampleCount {
    let process = Process()
    process.executableURL = executableURL
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    let start = clock.now
    try process.run()
    let timeout = start.advanced(by: .seconds(5))
    var visibleAt: ContinuousClock.Instant?

    while clock.now < timeout {
      if hasVisibleWindow(processIdentifier: process.processIdentifier) {
        visibleAt = clock.now
        break
      }
      usleep(1_000)
    }

    if process.isRunning {
      process.terminate()
    }
    process.waitUntilExit()

    guard let visibleAt else {
      throw ProbeError.windowTimeout(sample: sampleIndex)
    }

    let elapsed = milliseconds(start.duration(to: visibleAt))
    samples.append(elapsed)
    print("sample_\(sampleIndex)_ms=\(String(format: "%.3f", elapsed))")
  }

  let sortedSamples = samples.sorted()
  print("p50_ms=\(String(format: "%.3f", percentile(sortedSamples, 0.50)))")
  print("p95_ms=\(String(format: "%.3f", percentile(sortedSamples, 0.95)))")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(EX_USAGE)
}
