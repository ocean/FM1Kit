import FM1Kit
import FM1Rescue
import Foundation
import os

/// Asks the connected FM-1 to restart into the chip's download mode, over MIDI.
func enterDownloadMode() async throws {
    let updater = await chosenUpdater(try CoreMIDITransport(clientName: "fm1probe"))
    guard let current = await updater.identify() else {
        print("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
        exit(1)
    }
    print("Device:   \(current.text)")
    print("Asking it to restart into download mode. Nothing is written; switching it off and on leaves.")
    do {
        try await updater.enterDownloadMode()
        print("The FM-1 is in download mode. Back it up with `sudo .build/debug/fm1probe flash-backup FOLDER`.")
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Reads the whole flash of an FM-1 in download mode (or a simulated one) and saves it to a
/// folder, as M-Flasher saves backups.
func backUpFlash(folderPath: String, isSimulated: Bool, traces: Bool) throws {
    let start = ContinuousClock.now
    let session = openFlashSession(
        command: "flash-backup \(folderPath)", simulating: isSimulated ? SimulatedDownloadMode() : nil, traces: traces)
    defer { session.close() }
    let backup = readFlash(session)
    let files = try save(backup, to: folderPath)
    let seconds = milliseconds(ContinuousClock.now - start) / 1000
    print(
        """

        Read the flash twice in \(String(format: "%.1f", seconds)) s: both reads and the chip's CRC-32 match.
        Bootloader: \(backup.bootloaderDescription)
        Firmware:   \(describeFirmware(backup))
        SHA-256:    \(backup.sha256)
        Saved:      \(files.flash.path)
                    \(files.description.path)

        Nothing was written to the FM-1. Switch it off and on to leave download mode.
        """)
}

/// Opens the FM-1 in download mode (or a simulated one) and starts the flash loader, printing
/// what it reports, or explains why it can't and exits.
///
/// - Parameters:
///   - command: The command and its arguments, to repeat if it needs sudo.
///   - simulated: A simulated FM-1 to use instead.
///   - traces: Print every USB transfer.
/// - Returns: The session, with the flash loader running.
func openFlashSession(command: String, simulating simulated: SimulatedDownloadMode?, traces: Bool) -> FlashSession {
    let connection: any DownloadModeConnection
    if let simulated {
        connection = simulated
    } else {
        connection = openDownloadMode(command: command, traces: traces)
    }
    let session: FlashSession
    do {
        session = try FlashSession(connection: connection)
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
    let mhz = session.clockMHz > 0 ? ", CPU at \(session.clockMHz) MHz" : ""
    print("Loader:   m-bootloader's flash loader \(session.loaderVersion)\(mhz)")
    let keyNote = session.chipKey == FlashSession.expectedChipKey ? "" : " (0x980F expected)"
    print("Chip key: " + String(format: "0x%04X", session.chipKey) + keyNote)
    print("Flash:    " + String(format: "0x%06X", session.flashID) + ", 1 MB")
    print("Unit ID:  \(session.uniqueID ?? "none")")
    return session
}

/// Reads the whole flash twice, printing progress in tenths, or explains why it couldn't and
/// exits.
func readFlash(_ session: FlashSession) -> FlashBackup {
    let progress = TenthsPrinter(label: "reading")
    do {
        return try session.backUp { progress.show($0) }
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Saves a backup to a folder, handing the files to the person who ran sudo.
func save(_ backup: FlashBackup, to folderPath: String) throws -> (flash: URL, description: URL) {
    let files = try backup.write(to: URL(fileURLWithPath: folderPath))
    giveToSudoUser([URL(fileURLWithPath: folderPath), files.flash, files.description])
    return files
}

/// The firmware in a backup, in a few words.
func describeFirmware(_ backup: FlashBackup) -> String {
    let firmware = backup.firmware
    return firmware.files == .missing ? "none installed" : "\(firmware.description), files \(firmware.filesDescription)"
}

/// Prints progress each time it passes another tenth.
final class TenthsPrinter: Sendable {
    let label: String
    private let shown = OSAllocatedUnfairLock(initialState: -1)

    init(label: String) {
        self.label = label
    }

    func show(_ fraction: Double) {
        let tenth = Int(fraction * 10)
        guard
            shown.withLock({ last in
                defer { last = max(last, tenth) }
                return tenth > last
            })
        else { return }
        print("\(timestamp())  \(label): \(tenth * 10)%")
    }
}

/// Opens the FM-1 in download mode, or explains why it can't and exits.
private func openDownloadMode(command: String, traces: Bool) -> any DownloadModeConnection {
    do {
        let usb = try USBDownloadModeConnection.open()
        if traces {
            let start = ContinuousClock.now
            usb.trace = { line in
                print(String(format: "%8.3f  ", milliseconds(ContinuousClock.now - start) / 1000) + line)
            }
        }
        return usb
    } catch DownloadModeError.needsRoot {
        print("This needs administrator rights: run `swift build`, then")
        print("`sudo .build/debug/fm1probe \(command)`.")
        exit(1)
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Run with sudo, the files saved still belong to the person who ran it.
func giveToSudoUser(_ urls: [URL]) {
    let environment = ProcessInfo.processInfo.environment
    guard let uid = environment["SUDO_UID"].flatMap(UInt32.init), let gid = environment["SUDO_GID"].flatMap(UInt32.init)
    else {
        return
    }
    for url in urls {
        chown(url.path, uid, gid)
    }
}
