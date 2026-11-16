import FM1Kit
import FM1Rescue
import Foundation
import os

/// Asks the connected FM-1 to restart into the chip's download mode, over MIDI.
func enterDownloadMode() async throws {
    let updater = await chosenUpdater(try await CoreMIDITransport(clientName: "fm1probe"))
    guard let current = await updater.identify() else {
        stop("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
    }
    Style.heading("FM-1")
    print(Style.bold("Device:") + "   \(current.text)")
    print("Asking it to restart into download mode. Nothing is written; switching it off and on leaves.")
    do {
        try await updater.enterDownloadMode()
        print("\n" + Style.done("The FM-1 is in download mode."))
        Style.nextSteps(["Back it up: `sudo .build/debug/fm1probe flash-backup FOLDER`."])
    } catch {
        stop(error.localizedDescription)
    }
}

/// Reads the whole flash of an FM-1 in download mode (or a simulated one) and saves it to a
/// folder, as M-Flasher saves backups.
func backUpFlash(folderPath: String, isSimulated: Bool, traces: Bool) throws {
    Style.heading("FM-1")
    let session = openFlashSession(
        command: "flash-backup \(folderPath)", simulating: isSimulated ? SimulatedDownloadMode() : nil, traces: traces)
    defer { session.close() }
    // Timed once the FM-1 is caught, so `--wait` doesn't count.
    let start = ContinuousClock.now
    let backup = readFlash(session)
    let files = try save(backup, to: folderPath)
    let seconds = milliseconds(ContinuousClock.now - start) / 1000
    print(
        "\n"
            + Style.done(
                "Read the flash twice in \(String(format: "%.1f", seconds)) s: both reads and the chip's CRC-32 match.")
    )
    Style.heading("Backup")
    print(Style.bold("Bootloader:") + " \(backup.bootloaderDescription)")
    print(Style.bold("Firmware:") + "   \(describeFirmware(backup))")
    print(Style.bold("SHA-256:") + "    \(backup.sha256)")
    print(Style.bold("Saved:") + "      \(files.flash.path)")
    print("            \(files.description.path)")
    print("\nNothing was written to the FM-1.")
    Style.nextSteps(["Switch the FM-1 off and on to leave download mode."])
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
        stop(error.localizedDescription)
    }
    let mhz = session.clockMHz > 0 ? ", CPU at \(session.clockMHz) MHz" : ""
    print(Style.bold("Loader:") + "   m-bootloader's flash loader \(session.loaderVersion)\(mhz)")
    let keyNote = session.chipKey == FlashSession.expectedChipKey ? "" : " (0x980F expected)"
    print(Style.bold("Chip key:") + " " + String(format: "0x%04X", session.chipKey) + keyNote)
    let chipNote =
        session.flashID == FM1FlashChip.uc25hq80
        ? " (the newer chip, UC25HQ80: firmwares that don't know it keep saves only until switched off)" : ""
    print(Style.bold("Flash:") + "    " + String(format: "0x%06X", session.flashID) + ", 1 MB" + chipNote)
    print(Style.bold("Unit ID:") + "  \(session.uniqueID ?? "none")")
    return session
}

/// Reads the whole flash twice, printing progress in tenths, or explains why it couldn't and
/// exits.
func readFlash(_ session: FlashSession) -> FlashBackup {
    let progress = TenthsPrinter(label: "reading")
    do {
        return try session.backUp { progress.show($0) }
    } catch {
        stop(error.localizedDescription)
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
        print(Style.progress("\(label): \(tenth * 10)%"))
    }
}

/// Opens the FM-1 in download mode, or explains why it can't and exits.
///
/// With `--wait SECONDS`, it waits that long for the FM-1 to appear there and catches it as soon
/// as it does.
private func openDownloadMode(command: String, traces: Bool) -> any DownloadModeConnection {
    let wait = downloadModeWait()
    do {
        let usb: USBDownloadModeConnection
        if let wait {
            // Without root it stops at once, so only promise to wait with it.
            if geteuid() == 0 {
                print(
                    """
                    Waiting up to \(wait.components.seconds) s for the FM-1 in download mode. Switch it on \
                    now, or hold REC while switching it on (m-bootloader). If macOS asks to allow the \
                    accessory, click Allow.
                    """)
            }
            usb = try USBDownloadModeConnection.open(waitingUpTo: wait)
            print(Style.logged("Caught the FM-1 in download mode."))
        } else {
            usb = try USBDownloadModeConnection.open()
        }
        if traces {
            let start = ContinuousClock.now
            usb.trace = { line in
                print(String(format: "%8.3f  ", milliseconds(ContinuousClock.now - start) / 1000) + line)
            }
        }
        return usb
    } catch DownloadModeError.needsRoot {
        let waitOption = wait.map { " --wait \($0.components.seconds)" } ?? ""
        stop(
            """
            This needs administrator rights: run `swift build`, then \
            `sudo .build/debug/fm1probe \(command)\(waitOption)`.
            """)
    } catch DownloadModeError.notFound where wait != nil {
        stop("The FM-1 didn't appear in download mode in time. Nothing was written.")
    } catch {
        stop(error.localizedDescription)
    }
}

/// How long `--wait SECONDS` says to wait for download mode, if it's given; exits when it isn't
/// a number of seconds from 1 to 600.
private func downloadModeWait() -> Duration? {
    guard arguments.contains("--wait") else { return nil }
    guard let seconds = option("--wait").flatMap(Int.init), (1...600).contains(seconds) else {
        stop("--wait needs a number of seconds from 1 to 600, such as --wait 120.")
    }
    return .seconds(seconds)
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
