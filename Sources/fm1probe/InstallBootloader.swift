import FM1Kit
import Foundation

/// Installs m-bootloader from its installer package on the connected FM-1 (or a simulated one),
/// after the person types YES.
func installBootloader(path: String, isSimulated: Bool, fromAnyFirmware: Bool, logPath: String?) async throws {
    let installer: BootloaderInstaller
    do {
        installer = try BootloaderInstaller(package: FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: path))))
    } catch {
        print("\(path) can't be used: \(error.localizedDescription)")
        exit(1)
    }
    let device: any MIDITransport
    if isSimulated {
        var options = SimulatedFM1.Options()
        options.installedIdentity = FM1Identity.officialV15
        let simulated = SimulatedFM1(options: options)
        simulated.prepare(for: installer.package)
        device = simulated
    } else {
        device = try CoreMIDITransport(clientName: "fm1probe")
    }
    if let logPath, FileManager.default.fileExists(atPath: logPath) {
        print("\(logPath) already exists. Choose a new name for the log, so an earlier one isn't lost.")
        exit(1)
    }
    let transport: any MIDITransport =
        try logPath.map { LoggingTransport(device, log: try MessageLog(path: $0)) } ?? device
    let updater = await chosenUpdater(transport)
    print("Installs: m-bootloader \(installer.bootloader.version) (\(installer.bootloader.bytes.count) bytes)")
    guard let current = await updater.identify() else {
        print("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
        exit(1)
    }
    print("Device:   \(current.text)")
    if fromAnyFirmware, current != FM1Identity.officialV15 {
        print("Testing: sending the installer to \(current.text), not V15. Most firmwares refuse it while staging.")
    } else if current != FM1Identity.officialV15 {
        print("Installing m-bootloader needs the FM-1 running V15 (FM-1_015). Install V15 first.")
        exit(1)
    }
    if !isSimulated, !confirmBootloaderInstall() {
        print("Stopped. Nothing was sent apart from the handshake query.")
        exit(1)
    }
    if let logPath { print("Logging every message to \(logPath).") }
    let start = ContinuousClock.now
    do {
        let identity = try await updater.installBootloader(
            installer, fromAnyFirmware: fromAnyFirmware, events: printBootloaderEvent)
        let seconds = milliseconds(ContinuousClock.now - start) / 1000
        print(
            """

            The FM-1 is back on \(identity.text) after \(String(format: "%.1f", seconds)) s. Its screen should have
            shown INSTALLED: FM1Kit can't read the bootloader back over USB-MIDI to check. To make sure,
            switch the FM-1 off, then hold PLAY while switching it on: m-bootloader's menu should open.
            """)
    } catch {
        print("\nStopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Prints the steps of a bootloader install worth showing.
@Sendable func printBootloaderEvent(_ event: UpdateEvent) {
    switch event {
    case .staging(let requests) where requests.isMultiple(of: 10):
        print("\(timestamp())  staging: \(requests) requests")
    case .rebooting: print("\(timestamp())  restarting: the installer is writing the bootloader")
    case .finished(let identity): print("\(timestamp())  back: \(identity.text)")
    default: break
    }
}

/// Explains what installing the bootloader does, and asks the person to type YES.
func confirmBootloaderInstall() -> Bool {
    print(
        """

        This replaces the FM-1's bootloader with m-bootloader, keeping V15 and your projects. V15
        takes the installer like an update and restarts; the installer then rewrites the 16 KB boot
        area, shows INSTALLED and restarts into V15. Keep the cable connected and the FM-1 powered
        until V15 is back: losing power while the boot area is written can leave the FM-1 unable to
        start, and only a USB_KEY dongle can recover it then. Installing V15 later puts M-VAVE's
        bootloader back. Firmwares with Felucca's original update check (AMB-1, HYP-1, DUB-1) refuse
        V15 over USB-MIDI while m-bootloader is installed: from them, install V15 in download mode.

        """)
    print("Type YES to install m-bootloader, or anything else to stop: ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES"
}
