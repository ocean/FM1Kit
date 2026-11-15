import FM1Kit
import Foundation
import os

/// Writes a firmware's resources (a `NAME-res.bin`, or a package that carries them) to the
/// connected FM-1 (or a simulated one) over USB-MIDI, after the person types YES.
func writeResources(path: String, isSimulated: Bool, logPath: String?) async throws {
    let resources = try loadResources(path)
    let device: any MIDITransport
    if isSimulated {
        var options = SimulatedFM1.Options()
        options.buildResources = resources
        device = SimulatedFM1(options: options)
    } else {
        device = try await CoreMIDITransport(clientName: "fm1probe")
    }
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
    print(Style.bold("Device:") + "    \(current.text)")
    print(
        Style.bold("Resources:")
            + " \(resources.payloadLength) bytes, CRC-32 \(String(format: "%08x", resources.payloadCRC))")
    if current.isLoader {
        stop("The FM-1 is in its update loader. Finish the install first: `fm1probe install FILE.fwsc --resume`.")
    }
    if !isSimulated, !confirmResourceWrite() {
        stop("Nothing was sent apart from the handshake query.")
    }
    Style.heading("Writing")
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
            print(Style.progress("resources: \(tenth * 10)%"))
        }
        let seconds = milliseconds(ContinuousClock.now - start) / 1000
        print(Style.done("The resources are on the FM-1 (\(String(format: "%.1f", seconds)) s)."))
        Style.nextSteps(["Switch the FM-1 off and on, so the firmware loads them."])
    } catch {
        print("")
        stop(error.localizedDescription)
    }
}

/// The resources in a `NAME-res.bin`, or in a package that carries them in fm1-base's form;
/// stops fm1probe for anything else.
func loadResources(_ path: String) throws -> ResourceRegion {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if path.lowercased().hasSuffix(".fwsc") {
        guard let resources = try FwscPackage(data: data).resources else {
            stop("\(path) carries no resources that fm1probe can write over USB-MIDI.")
        }
        return resources
    }
    do {
        return try ResourceRegion(bytes: [UInt8](data))
    } catch {
        stop("\(path): \(error.localizedDescription)")
    }
}

/// Says what writing resources does, and asks the person to type YES.
func confirmResourceWrite() -> Bool {
    Style.heading("Confirm")
    print(
        """
        This asks the firmware the FM-1 is running to write these resources (its samples or other
        data) into its resource region. It takes only its own build's, erases the region, writes
        them and checks them; projects and settings stay as they are. Press STOP first. If it's
        interrupted, the firmware does without its resources until you write them again.
        """)
    print(Style.bold("Type YES to write the resources, or anything else to stop: "), terminator: "")
    return readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES"
}
