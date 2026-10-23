import FM1Kit
import FM1Rescue
import Foundation
import os

/// Asks the connected FM-1 to restart into the chip's download mode, over MIDI.
func enterDownloadMode() async throws {
    let updater = FM1Updater(transport: try CoreMIDITransport(clientName: "fm1probe"))
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
    let connection = openDownloadMode(folderPath: folderPath, isSimulated: isSimulated, traces: traces)
    defer { connection.close() }
    let start = ContinuousClock.now
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

    let shown = OSAllocatedUnfairLock(initialState: -1)
    let backup: FlashBackup
    do {
        backup = try session.backUp { fraction in
            let tenth = Int(fraction * 10)
            guard
                shown.withLock({ last in
                    defer { last = max(last, tenth) }
                    return tenth > last
                })
            else { return }
            print("\(timestamp())  reading: \(tenth * 10)%")
        }
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
    let files = try backup.write(to: URL(fileURLWithPath: folderPath))
    giveToSudoUser([URL(fileURLWithPath: folderPath), files.flash, files.description])
    let seconds = milliseconds(ContinuousClock.now - start) / 1000
    print(
        """

        Read the flash twice in \(String(format: "%.1f", seconds)) s: both reads and the chip's CRC-32 match.
        Bootloader: \(backup.bootloaderDescription)
        SHA-256:    \(backup.sha256)
        Saved:      \(files.flash.path)
                    \(files.description.path)

        Nothing was written to the FM-1. Switch it off and on to leave download mode.
        """)
}

/// Opens the FM-1 in download mode (or a simulated one), or explains why it can't and exits.
private func openDownloadMode(folderPath: String, isSimulated: Bool, traces: Bool) -> any DownloadModeConnection {
    guard !isSimulated else { return SimulatedDownloadMode() }
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
        print("`sudo .build/debug/fm1probe flash-backup \(folderPath)`.")
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
