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
            print(Style.colour("[FAIL]", .red) + " " + Style.bold("Package"))
            print("  \(error.localizedDescription)")
        }
        exit(1)
    }
    let report = PackageCheck(package)
    let strict = arguments.contains("--strict")
    if isJSON {
        printJSON(
            CheckJSON(
                file: path,
                product: package.product,
                sha256: package.sha256,
                passes: report.passes,
                worst: report.worst,
                findings: report.findings))
        if !report.passes || (strict && report.worst == .warning) { exit(1) }
        return
    }
    Style.heading(package.product)
    print(Style.dim("SHA-256 \(package.sha256)"))
    for finding in report.findings {
        print("")
        print("\(outcomeLabel(finding.outcome)) \(Style.bold(topicLabel(finding.topic)))")
        print("  " + finding.summary)
    }
    Style.heading("Verdict")
    switch report.worst {
    case .failure:
        print(Style.colour("Not ready: fix the failures above.", .red))
        exit(1)
    case .warning where strict:
        print(Style.colour("Warnings above, and --strict treats them as failures.", .red))
        exit(1)
    case .warning:
        print(Style.colour("Ready, with warnings above.", .yellow))
    case .pass, .note:
        print(Style.done("Ready."))
    }
}

/// The outcome as a fixed-width tag.
private func outcomeLabel(_ outcome: PackageCheck.Outcome) -> String {
    switch outcome {
    case .pass: Style.colour("[ok]  ", .green)
    case .note: Style.colour("[note]", .cyan)
    case .warning: Style.colour("[warn]", .yellow)
    case .failure: Style.colour("[FAIL]", .red)
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
