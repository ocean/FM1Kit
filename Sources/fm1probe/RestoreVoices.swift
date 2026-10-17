import FM1Kit
import Foundation
import os

/// Restores V15's factory voices on the connected FM-1 (or a simulated one), after the person
/// types YES.
func restoreVoices(path: String, isSimulated: Bool, logPath: String?) async throws {
    let package = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: path)))
    guard package.hasFactoryVoices else {
        print("\(path) isn't M-VAVE's official V15 package, so it has no factory voices to restore.")
        exit(1)
    }
    let device: any MIDITransport
    if isSimulated {
        var options = SimulatedFM1.Options()
        options.installedIdentity = FM1Identity.officialV15
        device = SimulatedFM1(options: options)
    } else {
        device = try CoreMIDITransport(clientName: "fm1probe")
    }
    if let logPath, FileManager.default.fileExists(atPath: logPath) {
        print("\(logPath) already exists. Choose a new name for the log, so an earlier one isn't lost.")
        exit(1)
    }
    let transport: any MIDITransport =
        try logPath.map { LoggingTransport(device, log: try MessageLog(path: $0)) } ?? device
    let updater = FM1Updater(transport: transport)
    guard let current = await updater.identify() else {
        print("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
        exit(1)
    }
    print("Device:   \(current.text)")
    guard current == FM1Identity.officialV15 else {
        print("Restoring the factory voices needs the FM-1 running V15 (FM-1_015). Install V15 first.")
        exit(1)
    }
    if !isSimulated, !confirmVoiceRestore() {
        print("Stopped. Nothing was sent apart from the handshake query.")
        exit(1)
    }
    if let logPath { print("Logging every message to \(logPath).") }
    let start = ContinuousClock.now
    let shown = OSAllocatedUnfairLock(initialState: -1)
    do {
        try await updater.restoreFactoryVoices(from: package) { fraction in
            let tenth = Int(fraction * 10)
            guard
                shown.withLock({ last in
                    defer { last = max(last, tenth) }
                    return tenth > last
                })
            else { return }
            print("\(timestamp())  voices: \(tenth * 10)%")
        }
        let seconds = milliseconds(ContinuousClock.now - start) / 1000
        print("\nRestored V15's factory voices in \(String(format: "%.1f", seconds)) s. Switch voices to hear them.")
    } catch {
        print("\nStopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Warns that a voice restore replaces every voice for good, and asks the person to type YES.
func confirmVoiceRestore() -> Bool {
    print(
        """

        This erases the FM-1's four voice banks and writes V15's 128 factory voices in their place.
        Every voice in them is replaced for good, including any you made, and V15 can't read them
        back first. Keep the cable connected until it finishes; if it's interrupted, some voices
        may be wrong or silent until you run it again.

        """)
    print("Type YES to restore the factory voices, or anything else to stop: ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES"
}
