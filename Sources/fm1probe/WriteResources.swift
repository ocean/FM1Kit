import FM1Kit
import Foundation
import os

/// Writes a firmware's resources (a `NAME-res.bin`) to the connected FM-1 (or a simulated one)
/// over USB-MIDI, after the person types YES.
func writeResources(path: String, isSimulated: Bool, logPath: String?) async throws {
    let resources: ResourceRegion
    do {
        resources = try ResourceRegion(bytes: [UInt8](Data(contentsOf: URL(fileURLWithPath: path))))
    } catch let failure as ResourceRegion.Failure {
        print("\(path): \(failure.localizedDescription)")
        exit(1)
    }
    let device: any MIDITransport
    if isSimulated {
        var options = SimulatedFM1.Options()
        options.buildResources = resources
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
    let updater = await chosenUpdater(transport)
    guard let current = await updater.identify() else {
        print("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
        exit(1)
    }
    print("Device:    \(current.text)")
    print("Resources: \(resources.payloadLength) bytes, CRC-32 \(String(format: "%08x", resources.payloadCRC))")
    if current.isLoader {
        print("The FM-1 is in its update loader. Finish the install first: `fm1probe install FILE.fwsc --resume`.")
        exit(1)
    }
    if !isSimulated, !confirmResourceWrite() {
        print("Stopped. Nothing was sent apart from the handshake query.")
        exit(1)
    }
    if let logPath { print("Logging every message to \(logPath).") }
    let start = ContinuousClock.now
    let shown = OSAllocatedUnfairLock(initialState: -1)
    do {
        try await updater.writeResources(resources) { fraction in
            let tenth = Int(fraction * 10)
            guard
                shown.withLock({ last in
                    defer { last = max(last, tenth) }
                    return tenth > last
                })
            else { return }
            print("\(timestamp())  resources: \(tenth * 10)%")
        }
        let seconds = milliseconds(ContinuousClock.now - start) / 1000
        print("\nThe resources are on the FM-1 (\(String(format: "%.1f", seconds)) s).")
    } catch {
        print("\nStopped: \(error.localizedDescription)")
        exit(1)
    }
}

/// Says what writing resources does, and asks the person to type YES.
func confirmResourceWrite() -> Bool {
    print(
        """

        This asks the firmware the FM-1 is running to write these resources (its samples or other
        data) into its resource region. It takes only its own build's, erases the region, writes
        them and checks them; projects and settings stay as they are. Press STOP first. If it's
        interrupted, the firmware does without its resources until you write them again.

        """)
    print("Type YES to write the resources, or anything else to stop: ", terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES"
}
