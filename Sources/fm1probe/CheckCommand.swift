import FM1Kit
import Foundation

/// Runs `check`: a pre-release report on a firmware package, read from the package alone.
///
/// Exits with 1 when a finding fails, or, with `--strict`, when one warns.
///
/// - Parameter arguments: The command, the package, then options.
/// - Throws: Any error reading the package.
func checkPackage(_ arguments: [String]) throws {
    let path = arguments[1]
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let package: FwscPackage
    do {
        package = try FwscPackage(data: data)
    } catch {
        if isJSON {
            printJSON(ErrorJSON(format: "fm1probe-check-1", file: path, error: error.localizedDescription))
        } else {
            print("[FAIL] Package")
            print("  \(error.localizedDescription)")
        }
        exit(1)
    }
    let report = PackageCheck(package)
    let strict = arguments.contains("--strict")
    if isJSON {
        printJSON(
            CheckJSON(
                file: path, product: package.product, sha256: package.sha256, passes: report.passes,
                worst: report.worst, findings: report.findings))
        if !report.passes || (strict && report.worst == .warning) { exit(1) }
        return
    }
    print("\(package.product), SHA-256 \(package.sha256)")
    for finding in report.findings {
        print("")
        let label = "\(outcomeLabel(finding.outcome)) \(topicLabel(finding.topic))"
        print(label)
        print("  " + finding.summary)
    }
    print("")
    switch report.worst {
    case .failure:
        print("Not ready: fix the failures above.")
        exit(1)
    case .warning where strict:
        print("Warnings above, and --strict treats them as failures.")
        exit(1)
    case .warning:
        print("Ready, with warnings above.")
    case .pass, .note:
        print("Ready.")
    }
}

/// The outcome as a fixed-width tag.
private func outcomeLabel(_ outcome: PackageCheck.Outcome) -> String {
    switch outcome {
    case .pass: "[ok]  "
    case .note: "[note]"
    case .warning: "[warn]"
    case .failure: "[FAIL]"
    }
}

/// The topic as a heading.
private func topicLabel(_ topic: PackageCheck.Topic) -> String {
    switch topic {
    case .identity: "Identity"
    case .chipKey: "Chip key"
    case .flashChips: "Flash chips"
    case .savedData: "Saved data"
    case .installing: "Installing it"
    case .leaving: "Switching away"
    case .recovery: "Recovery"
    }
}
