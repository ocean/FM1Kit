import FM1Kit
import FM1Rescue
import Foundation

/// Something about each file as a whole, printed before the parts.
struct DiffField: Encodable {
    let name: String
    let first: String
    let second: String
    var isSame: Bool { first == second }

    /// The text to print, with the name padded to `width`; differing hashes are shortened.
    func text(width: Int) -> String {
        let label = (name + ":").padding(toLength: width + 2, withPad: " ", startingAt: 0)
        if isSame { return "\(label)same, \(first)" }
        func short(_ value: String) -> String {
            value.count == 64 && value.allSatisfy(\.isHexDigit) ? value.prefix(16) + "…" : value
        }
        return "\(label)\(short(first)) → \(short(second))"
    }
}

/// `diff --json`.
struct DiffJSON: Encodable {
    let format = "fm1probe-diff-1"
    let first: String
    let second: String
    let kind: String
    let same: Bool
    let fields: [DiffField]
    let parts: [FlashComparison.Part]
}

/// Runs `diff`: compares two packages or two flash backups, part by part; sends nothing.
///
/// Exits with 0 when they're the same, 1 when they differ and 2 when they can't be compared,
/// as diff(1) does.
///
/// - Parameters:
///   - firstPath: The first file.
///   - secondPath: The second file, of the same kind.
func diff(_ firstPath: String, _ secondPath: String) {
    let isBackup = (firstPath.lowercased().hasSuffix(".bin"), secondPath.lowercased().hasSuffix(".bin"))
    do {
        switch isBackup {
        case (true, true):
            let first = try FlashBackup(contentsOf: URL(fileURLWithPath: firstPath))
            let second = try FlashBackup(contentsOf: URL(fileURLWithPath: secondPath))
            report(
                firstPath, secondPath, kind: "flashBackup", backupFields(first, second), first.compared(with: second))
        case (false, false):
            let first = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: firstPath)))
            let second = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: secondPath)))
            report(firstPath, secondPath, kind: "package", packageFields(first, second), first.compared(with: second))
        default:
            cannotCompare(
                firstPath, secondPath, "Compare two packages (.fwsc) or two flash backups (.bin), not one of each.")
        }
    } catch {
        cannotCompare(firstPath, secondPath, error.localizedDescription)
    }
}

private func cannotCompare(_ firstPath: String, _ secondPath: String, _ reason: String) -> Never {
    if isJSON {
        printJSON(ErrorJSON(format: "fm1probe-diff-1", file: "\(firstPath), \(secondPath)", error: reason))
    } else {
        print(reason)
    }
    exit(2)
}

private func report(
    _ firstPath: String, _ secondPath: String, kind: String, _ fields: [DiffField], _ comparison: FlashComparison?
) -> Never {
    let parts = comparison?.parts ?? []
    let isSame = fields.allSatisfy(\.isSame) && (comparison?.isSame ?? true)
    if isJSON {
        printJSON(
            DiffJSON(first: firstPath, second: secondPath, kind: kind, same: isSame, fields: fields, parts: parts))
        exit(isSame ? 0 : 1)
    }
    print("First:  \(firstPath)")
    print("Second: \(secondPath)")
    print("")
    let nameWidth = fields.map(\.name.count).max() ?? 0
    for field in fields { print(field.text(width: nameWidth)) }
    if comparison == nil {
        print("")
        print("An installer package holds no firmware image, so there are no parts to compare.")
    }
    if !parts.isEmpty { print("") }
    let rangeWidth = parts.map(\.rangeText.count).max() ?? 0
    for part in parts {
        let range = part.rangeText.padding(toLength: rangeWidth, withPad: " ", startingAt: 0)
        let label = "[\(part.outcome.rawValue)]".padding(toLength: 9, withPad: " ", startingAt: 0)
        print("\(label) \(range)  \(part.name): \(part.detail)")
    }
    print("")
    print(isSame ? "The same." : "They differ.")
    exit(isSame ? 0 : 1)
}

private func packageFields(_ first: FwscPackage, _ second: FwscPackage) -> [DiffField] {
    func field(_ name: String, _ value: (FwscPackage) -> String) -> DiffField {
        DiffField(name: name, first: value(first), second: value(second))
    }
    return [
        field("Product") { $0.product },
        field("File size") { "\($0.fileBytes.count) bytes" },
        field("Image size") { $0.flashImage.map { "\($0.count) bytes" } ?? "none (installer)" },
        field("SHA-256") { $0.sha256 },
        field("Update loader") { package in
            switch package.updateLoader {
            case .mVaves: "M-VAVE's"
            case .feluccas: "Felucca's"
            case .other: "another, SHA-256 " + package.loaderSHA256.prefix(16) + "…"
            }
        },
        field("Flash chips") { package in
            switch package.flashChipSupport {
            case .bothChips: "checks for both"
            case .firstChipOnly: "checks for the first FM-1s' alone"
            case .noCheck: "doesn't check"
            case nil: "not known"
            }
        },
        field("Factory voices") { $0.hasFactoryVoices ? "included" : "not included" },
    ] + (first.isFirmware && second.isFirmware ? [] : [field("Installs", installedBootloader)])
}

/// The m-bootloader an installer package installs, or what else the package is.
private func installedBootloader(_ package: FwscPackage) -> String {
    if package.isFirmware { return "a firmware" }
    guard let bootloader = try? BootloaderInstaller(package: package).bootloader else { return "not known" }
    return "m-bootloader \(bootloader.version) for \(bootloader.board), SHA-256 \(bootloader.sha256)"
}

private func backupFields(_ first: FlashBackup, _ second: FlashBackup) -> [DiffField] {
    func field(_ name: String, _ value: (FlashBackup) -> String) -> DiffField {
        DiffField(name: name, first: value(first), second: value(second))
    }
    return [
        field("Unit ID") { $0.uniqueID ?? "not known" },
        field("Flash ID") { $0.flashID == 0 ? "not known" : String(format: "%06X", $0.flashID) },
        field("Bootloader") { $0.bootloaderDescription },
        field("Firmware") { $0.firmware.description },
        field("SHA-256") { $0.sha256 },
    ]
}
