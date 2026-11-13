import FM1Kit
import FM1Rescue
import Foundation

/// Runs `transporter`, which works with an FM-1 through the FM-1 Transporter: an RP2040 board
/// wired to its USB lines that reaches the chip's boot ROM when its firmware can't start.
///
/// - Parameter arguments: `transporter`, the action and its files, then options.
/// - Throws: Any error reading a file or saving a backup.
func runTransporter(_ arguments: [String]) throws {
    let files = arguments.dropFirst(2).filter { !$0.hasPrefix("--") && !optionValues.contains($0) }
    switch (arguments.count > 1 ? arguments[1] : "", files.count) {
    case ("status", 0):
        showTransporterStatus()
    case ("check", 0):
        let transporter = openTransporter()
        defer { transporter.close() }
        _ = prepareChip(transporter)
        print("\nNothing was written. Switch the FM-1 off and on to leave boot mode.")
    case ("backup", 1):
        let transporter = openTransporter()
        defer { transporter.close() }
        let chip = prepareChip(transporter)
        let backup = readTransporterFlash(transporter, chip)
        let saved = try save(backup, to: files[0])
        print(
            """

            Read the flash twice: both reads and the Transporter's CRC-32 match.
            Bootloader: \(backup.bootloaderDescription)
            Firmware:   \(describeFirmware(backup))
            SHA-256:    \(backup.sha256)
            Saved:      \(saved.flash.path)
                        \(saved.description.path)

            Nothing was written. Switch the FM-1 off and on to leave boot mode.
            """)
    case ("install", 2), ("restore", 2):
        try writeWithTransporter(restoring: arguments[1] == "restore", file: files[0], backupsPath: files[1])
    case ("start", 0):
        let transporter = openTransporter()
        defer { transporter.close() }
        do {
            try transporter.startFirmware()
        } catch {
            print("Stopped: \(error.localizedDescription)")
            exit(1)
        }
        print("The FM-1 has left boot mode and is starting its firmware.")
    default:
        print(usage)
        exit(2)
    }
}

/// The options that take a value, so their values aren't taken for files.
private let optionValues = Set(["--port", "--loader", "--wait", "--simulated"].compactMap(option))

/// Opens the Transporter's data port, or a simulated Transporter with `--simulated BACKUP.bin`,
/// or explains why it can't and exits.
private func openTransporter() -> Transporter {
    if let path = option("--simulated") {
        guard let backup = try? FlashBackup(contentsOf: URL(fileURLWithPath: path)) else {
            print("\(path) isn't a 1 MB flash backup.")
            exit(1)
        }
        let simulated = SimulatedTransporter(flash: backup.bytes)
        simulated.isWaitingForFM1 = true
        print("Simulating a Transporter wired to the FM-1 in \(path): nothing real is written.")
        return Transporter(link: simulated)
    }
    do {
        let link = try SerialTransporterLink.find(path: option("--port"))
        print("Transporter: \(link.path)")
        return Transporter(link: link)
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Says what the Transporter reports, without waiting for the FM-1 or sending anything to it.
private func showTransporterStatus() {
    let transporter = openTransporter()
    defer { transporter.close() }
    do {
        guard let status = try transporter.status() else {
            print("FM-1:   not answering yet. If the Transporter's LED blinks red, it's waiting for the FM-1")
            print("        to be switched on.")
            return
        }
        let state =
            status.isInBootMode ? "in boot mode" : status.isRunningV15 ? "running V15" : "not connected or starting"
        print("FM-1:   \(state)")
        print("Loader: \(status.hasLoader ? "sent" : "not sent yet")")
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Waits for the FM-1 to reach boot mode, sends the flash loader and checks the chip, printing
/// what it reports, or explains why it can't and exits.
private func prepareChip(_ transporter: Transporter) -> Transporter.Chip {
    var loader = Transporter.Loader.mBootloader
    if let loaderPath = option("--loader") {
        guard let bytes = try? [UInt8](Data(contentsOf: URL(fileURLWithPath: loaderPath))) else {
            print("\(loaderPath) couldn't be read.")
            exit(1)
        }
        loader = .wl82loader(bytes)
    }
    let wait = option("--wait").flatMap(Int.init) ?? 120
    do {
        let status = try transporter.waitForBootMode(timeout: .seconds(wait)) {
            print(
                """
                Waiting up to \(wait) s for the FM-1. Switch it on now: the Transporter's LED stops \
                blinking red, briefly shows other colours, then shows green alone.
                """)
        }
        print("\(timestamp())  The FM-1 is in boot mode.")
        try transporter.sendLoader(loader, status: status)
        let chip = try transporter.chip()
        print("Chip key: " + String(format: "0x%04X", chip.key))
        print("Flash:    \(flashChipDescription(chip.flashID))")
        return chip
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Reads the whole flash twice, printing progress in tenths, or explains why it couldn't and
/// exits.
private func readTransporterFlash(_ transporter: Transporter, _ chip: Transporter.Chip) -> FlashBackup {
    let progress = TenthsPrinter(label: "reading")
    do {
        return try transporter.backUp(chip) { progress.show($0) }
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Installs a firmware package or restores a backup through the Transporter: reads the flash and
/// saves it first, shows what would change, and writes and checks it after the person types YES.
private func writeWithTransporter(restoring: Bool, file: String, backupsPath: String) throws {
    let incoming = URL(fileURLWithPath: file)
    let package = restoring ? nil : try FwscPackage(data: Data(contentsOf: incoming))
    let backup = restoring ? try FlashBackup(contentsOf: incoming) : nil
    let transporter = openTransporter()
    defer { transporter.close() }
    let chip = prepareChip(transporter)
    let current = readTransporterFlash(transporter, chip)
    print("Bootloader: \(current.bootloaderDescription)")
    print("Firmware:   \(describeFirmware(current))")
    guard let plan = planTransporterWrite(package: package, backup: backup, onto: current) else { return }
    let saved = try save(current, to: backupsPath)
    print("The FM-1's flash as it is now is saved in \(saved.flash.path).")
    if option("--simulated") == nil, !confirmTransporterWrite() {
        print("Stopped. Nothing was written. Switch the FM-1 off and on to leave boot mode.")
        exit(1)
    }
    let start = ContinuousClock.now
    let progress = TenthsPrinter(label: "writing")
    do {
        try transporter.write(plan) { progress.show($0) }
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
    let seconds = milliseconds(ContinuousClock.now - start) / 1000
    print(
        """

        Written and read back in \(String(format: "%.1f", seconds)) s: every changed sector matches.
        Switch the FM-1 off, wait 5 seconds, unplug the Transporter's cable and switch it on.
        """)
    for step in plan.afterwards { print(step) }
}

/// Plans installing a package or restoring a backup onto the flash just read and prints what
/// changes, or explains why it can't and exits.
///
/// - Returns: The plan, or `nil` when there's nothing to write.
private func planTransporterWrite(
    package: FwscPackage?, backup: FlashBackup?, onto current: FlashBackup
) -> FlashPlan? {
    let plan: FlashPlan
    do {
        if let package {
            plan = try FlashPlan.installingWithTransporter(package, onto: current)
        } else if let backup {
            plan = try FlashPlan.restoring(backup, onto: current)
        } else {
            return nil
        }
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
    print("")
    for note in plan.notes { print(note) }
    guard !plan.isEmpty else {
        print("Nothing to write: the FM-1 already holds this. Switch it off and on to leave boot mode.")
        return nil
    }
    print("Writes \(describeSectors(plan)).")
    for warning in plan.warnings { print("Warning: \(warning)") }
    if let sector = plan.sectors.first(where: { !FlashPlan.transporterWritable.contains($0) }) {
        print(
            String(format: "Stopped: this changes 0x%05X, ", sector)
                + """
                outside the 0x04000–0x92FFF the Transporter writes: the boot area, or the saved \
                data and factory data above it. Restore it in download mode instead, with \
                flash-restore. Nothing was written.
                """)
        exit(1)
    }
    return plan
}

/// Explains what writing through the Transporter risks, and asks the person to type YES.
private func confirmTransporterWrite() -> Bool {
    print(
        """

        Keep the FM-1 switched on and the Transporter connected until this finishes. If it \
        stops part-way, don't switch the FM-1 off: run the same command again to finish. The \
        boot area isn't written, so the Transporter can still reach the boot ROM.
        """)
    print("Type YES to write to the FM-1, or anything else to stop: ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES"
}
