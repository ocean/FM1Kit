import FM1Kit
import Foundation
import os

/// Backs up an FM-1 running M-VAVE's open firmware (or a simulated one) to a new folder, after
/// the person types YES.
func backUp(folderPath: String, isSimulated: Bool, logPath: String?) async throws {
    let folder = URL(fileURLWithPath: folderPath)
    if FileManager.default.fileExists(atPath: folder.path) {
        stop("\(folderPath) already exists. Choose a new folder, so an earlier backup isn't overwritten.")
    }
    let device: any MIDITransport =
        try await isSimulated ? simulatedOpenFirmware() : CoreMIDITransport(clientName: "fm1probe")
    if let logPath, FileManager.default.fileExists(atPath: logPath) {
        stop("\(logPath) already exists. Choose a new name for the log, so an earlier one isn't lost.")
    }
    let transport: any MIDITransport =
        logPath.map { LoggingTransport(device, log: MessageLog(path: $0)) } ?? device
    let updater = await chosenUpdater(transport)
    guard let current = await updater.identify() else {
        stop("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
    }
    Style.heading("FM-1")
    print(Style.bold("Device:") + "   \(current.text)")
    guard current.isOpenFirmware else {
        stop("Only M-VAVE's open firmware can be backed up; other firmwares have no known way to read their data.")
    }
    if !isSimulated, !confirmBackup() {
        stop("Nothing was sent apart from the handshake query.")
    }
    Style.heading("Reading")
    if let logPath { print("Logging every message to \(logPath).") }
    let start = ContinuousClock.now
    let shown = OSAllocatedUnfairLock(initialState: -1)
    do {
        let backup = try await updater.backUpOpenFirmware { fraction in
            let tenth = Int(fraction * 10)
            guard
                shown.withLock({ last in
                    defer { last = max(last, tenth) }
                    return tenth > last
                })
            else { return }
            print(Style.progress("reading: \(tenth * 10)%"))
        }
        let seconds = milliseconds(ContinuousClock.now - start) / 1000
        try backup.write(to: folder)
        print("\n" + Style.done("Read the FM-1 in \(String(format: "%.1f", seconds)) s and saved it to \(folderPath)."))
        Style.heading("Backup")
        printSummary(of: backup)
        Style.nextSteps(["M-VAVE's workbench can restore the .fm1 projects and the .fm1s sample bank."])
    } catch {
        print("")
        stop(error.localizedDescription)
    }
}

/// An FM-1 running open firmware, with one saved slot and a small sample bank, for rehearsals.
func simulatedOpenFirmware() -> SimulatedFM1 {
    var options = SimulatedFM1.Options()
    options.installedIdentity = FM1Identity(model: "FM-1", version: 8_000_012)
    options.projectSlots = [0: SimulatedFM1.ProjectSlot(name: "SIMULATED", project: options.workspace)]
    options.sampleBank = Array(repeating: 0, count: 4096)
    return SimulatedFM1(options: options)
}

/// Lists what a backup holds.
func printSummary(of backup: OpenFirmwareBackup) {
    print("  Workspace:  slot \(backup.currentSlot + 1)'s project, with any unsaved changes")
    for slot in backup.slots {
        print("  Slot \(String(format: "%2d", slot.index + 1)):    \(slot.name ?? "empty")")
    }
    print("  Samples:    \(backup.samples.map { "\($0.count) bytes" } ?? "none")")
}

/// Explains what a backup does to the FM-1 while it runs, and asks the person to type YES.
func confirmBackup() -> Bool {
    Style.heading("Confirm")
    print(
        """
        This reads the FM-1's 16 project slots, its current project and its sample bank. Open
        firmware can only read the project being edited, so each slot is loaded in turn; afterwards
        the current project is put back as it was, including unsaved changes. No slot is saved and
        the sample bank isn't written. Don't play or edit until it finishes, and keep the cable
        connected: if it's interrupted, the FM-1 may be left on another slot, with unsaved
        changes lost.
        """)
    print(Style.bold("Type YES to back up the FM-1, or anything else to stop: "), terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES"
}
