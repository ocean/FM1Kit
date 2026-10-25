import FM1Kit
import FM1Rescue
import Foundation

/// What a download-mode write puts on the FM-1.
enum FlashWrite {
    /// A full backup, from its `.bin` file.
    case restore(String)
    /// A bootloader: m-bootloader's `.boot` file or installer package, or a firmware package's
    /// own bootloader.
    case bootloader(String)
    /// A firmware package's image.
    case firmware(String, includingBootloader: Bool, erasingSettings: Bool)

    /// The command that runs it, to repeat if it needs sudo.
    var command: String {
        switch self {
        case .restore(let path): "flash-restore \(path)"
        case .bootloader(let path): "flash-bootloader \(path)"
        case .firmware(let path, _, _): "flash-install \(path)"
        }
    }
}

/// Runs `flash-restore`, `flash-bootloader` or `flash-install` from the command line's arguments.
///
/// - Parameter arguments: The command, its file and backups folder, then options.
/// - Throws: Any error reading a file or saving the backup.
func writeFlash(_ arguments: [String]) throws {
    guard arguments.count >= 3 else {
        print(usage)
        exit(1)
    }
    let write: FlashWrite =
        switch arguments[0] {
        case "flash-restore": .restore(arguments[1])
        case "flash-bootloader": .bootloader(arguments[1])
        default:
            .firmware(
                arguments[1],
                includingBootloader: arguments.contains("--with-bootloader"),
                erasingSettings: arguments.contains("--erase-settings")
            )
        }
    let simulated = arguments.firstIndex(of: "--simulated").flatMap { index in
        index + 1 < arguments.count ? arguments[index + 1] : nil
    }
    try writeFlash(write, backupsPath: arguments[2], simulatedPath: simulated, traces: arguments.contains("--trace"))
}

/// Writes to an FM-1 in download mode: reads its flash and saves a backup first, shows what
/// would change, and writes and checks it after the person types YES.
///
/// - Parameters:
///   - write: What to write.
///   - backupsPath: The folder for the backup saved before writing.
///   - simulatedPath: A backup to run against as a simulated FM-1, instead of a real one.
///   - traces: Print every USB transfer.
/// - Throws: Any error reading a file or saving the backup.
func writeFlash(_ write: FlashWrite, backupsPath: String, simulatedPath: String?, traces: Bool) throws {
    let simulated = try simulatedPath.map(simulatedFM1)
    let session = openFlashSession(
        command: "\(write.command) \(backupsPath)", simulating: simulated, traces: traces)
    defer { session.close() }
    let current = readFlash(session)
    print("Bootloader: \(current.bootloaderDescription)")
    print("Firmware:   \(describeFirmware(current))")

    let plan: FlashPlan
    do {
        plan = try makePlan(write, onto: current)
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
    print("")
    for note in plan.notes { print(note) }
    guard !plan.isEmpty else {
        print("Nothing to write: the FM-1 already holds this. Switch it off and on to leave download mode.")
        return
    }
    let runs = plan.runs.map { String(format: "0x%05X–0x%05X", $0.lowerBound, $0.upperBound - 1) }
    print("Writes \(plan.sectors.count) sectors of 4 KB: \(runs.joined(separator: ", ")).")
    for warning in plan.warnings { print("Warning: \(warning)") }

    let files = try save(current, to: backupsPath)
    print("The FM-1's flash as it is now is saved in \(files.flash.path).")
    if simulated == nil, !confirmFlashWrite(plan) {
        print("Stopped. Nothing was written. Switch the FM-1 off and on to leave download mode.")
        exit(1)
    }
    let start = ContinuousClock.now
    let progress = TenthsPrinter(label: "writing")
    do {
        try session.write(plan) { progress.show($0) }
    } catch {
        print("Stopped: \(error.localizedDescription)")
        switch error {
        case .writeNotVerified, .writeInterrupted:
            print("Restore it with `sudo .build/debug/fm1probe flash-restore \(files.flash.path) \(backupsPath)`.")
        default:
            break
        }
        exit(1)
    }
    let seconds = milliseconds(ContinuousClock.now - start) / 1000
    print(
        """

        Written and checked in \(String(format: "%.1f", seconds)) s: every changed run matches the chip's CRC-32.
        Switch the FM-1 off and on to start it.
        """)
}

/// Plans a write against the flash just read.
private func makePlan(_ write: FlashWrite, onto current: FlashBackup) throws -> FlashPlan {
    switch write {
    case .restore(let path):
        return try FlashPlan.restoring(FlashBackup(contentsOf: URL(fileURLWithPath: path)), onto: current)
    case .bootloader(let path):
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if path.lowercased().hasSuffix(".boot") {
            guard let bootloader = BootloaderImage(data: data) else {
                print("\(path) isn't an m-bootloader .boot file, or it's damaged. Nothing was written.")
                exit(1)
            }
            return try FlashPlan.installing(bootloader, onto: current)
        }
        let package = try FwscPackage(data: data)
        guard package.isFirmware else {
            return try FlashPlan.installing(BootloaderInstaller(package: package).bootloader, onto: current)
        }
        return try FlashPlan.installingBootloader(from: package, onto: current)
    case .firmware(let path, let includingBootloader, let erasingSettings):
        let package = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: path)))
        return try FlashPlan.installing(
            package, onto: current, includingBootloader: includingBootloader, erasingSettings: erasingSettings)
    }
}

/// A simulated FM-1 whose flash and unit ID are a saved backup's.
private func simulatedFM1(_ path: String) throws -> SimulatedDownloadMode {
    let backup = try FlashBackup(contentsOf: URL(fileURLWithPath: path))
    let chip = SimulatedDownloadMode(flash: backup.bytes)
    if let id = backup.uniqueID, id.count == 16 {
        chip.uniqueID = stride(from: 0, to: 16, by: 2).compactMap { offset in
            let start = id.index(id.startIndex, offsetBy: offset)
            return UInt8(id[start..<id.index(start, offsetBy: 2)], radix: 16)
        }
    }
    print("Simulating the FM-1 in \(path): nothing real is written.")
    return chip
}

/// Explains what writing in download mode risks, and asks the person to type YES.
private func confirmFlashWrite(_ plan: FlashPlan) -> Bool {
    let recovery =
        if plan.sectors.contains(where: { $0 < 0x4000 }) {
            "The boot area is written too, so recovering it could then need a USB_KEY dongle."
        } else if plan.original.mBootloader != nil {
            """
            The bootloader isn't touched: holding REC while switching it on still starts m-bootloader's \
            download mode, to restore the backup just saved.
            """
        } else {
            """
            The bootloader isn't touched, but with M-VAVE's bootloader download mode is reached through \
            the firmware, so a firmware left unable to start could need a USB_KEY dongle. Installing \
            m-bootloader first avoids that.
            """
        }
    print(
        """

        Keep the cable connected and the FM-1 powered until this finishes: if it's switched off \
        while writing, it may not start. \(recovery)
        """)
    print("Type YES to write to the FM-1, or anything else to stop: ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES"
}
