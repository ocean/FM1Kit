import FM1Kit
import Foundation
import os

/// Runs `simulate`: a simulated FM-1 on virtual CoreMIDI ports, for testing updaters; sends
/// nothing to any real device.
///
/// It prints each message as it passes and what the simulated FM-1 does, until the time is up or
/// Ctrl-C stops it.
///
/// - Parameters:
///   - packagePath: The package the updater will send; the simulated FM-1 checks every byte
///     against it, and ignores the upgrade command without one.
///   - seconds: How long to run, or `nil` to run until stopped.
/// - Throws: When the package can't be read or CoreMIDI can't create the ports.
func simulate(packagePath: String?, seconds: Int?) async throws {
    var options = SimulatedFM1.Options()
    if let text = option("--identity") {
        guard let identity = FM1Identity(text: text) else {
            print("\(text) isn't an identity an FM-1 reports, such as FM-1_015.")
            fail()
        }
        options.installedIdentity = identity
    } else {
        options.installedIdentity = .officialV15
    }
    if let hex = option("--flash-chip") {
        guard let id = UInt32(hex.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            print("\(hex) isn't a flash chip's JEDEC ID in hex, such as B36014.")
            fail()
        }
        options.flashChipID = id
    }
    options.startsInRecoveryMode = arguments.contains("--loader")
    options.serialNumber = nil
    options.responseTimeout = .seconds(10)

    let fm1 = SimulatedFM1(options: options)
    if let packagePath {
        let package = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: packagePath)))
        fm1.prepare(for: package)
        print("Expecting \(package.product) (SHA-256 \(package.sha256.prefix(16))…); each byte sent is checked.")
    } else {
        print("No package given, so the simulated FM-1 answers but ignores the upgrade command.")
    }
    let showsHex = arguments.contains("--hex")
    let showsEveryRead = arguments.contains("--all")
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let published = try CoreMIDIVirtualDevice(publishing: fm1, clientName: "fm1probe simulate") {
        sysex, direction, port in
        let description = FM1MessageDescription(sysex, direction: direction)
        // An install asks for hundreds of reads a second, so only every 100th is counted unless --all.
        if !showsEveryRead, description.kind == "read" || description.kind == "response" {
            let count = reads.withLock { count in
                if description.kind == "read" { count += 1 }
                return count
            }
            if description.kind == "read", count == 1 || count.isMultiple(of: 100) {
                print("\(timestamp())  ← \(port)  \(count) reads so far; the last \(description.detail)")
            }
            return
        }
        if description.kind == "upgrade" || description.kind == "finish" { reads.withLock { $0 = 0 } }
        let arrow = direction == .toDevice ? "→" : "←"
        print("\(timestamp())  \(arrow) \(port)  \(description.text)")
        if showsHex || isUnknown(description) {
            print("    \(hex(sysex))")
        }
    }
    let running = Task { try await published.run() }
    let identity = fm1.currentIdentity?.text ?? "nothing"
    print("A simulated FM-1 reporting \(identity) is on the virtual port \"\(SimulatedFM1.portName)\".")
    print(seconds.map { "Running for \($0) s." } ?? "Running until Ctrl-C.")

    let deadline = seconds.map { ContinuousClock.now + .seconds($0) }
    var shown = 0
    while deadline.map({ ContinuousClock.now < $0 }) ?? true {
        try await Task.sleep(for: .milliseconds(100))
        let events = fm1.events
        for event in events.dropFirst(shown) {
            print("\(timestamp())  simulated FM-1: \(event)")
        }
        shown = events.count
    }
    running.cancel()
    _ = await running.result
    print("Stopped. The simulated FM-1 reports \(fm1.currentIdentity?.text ?? "nothing, restarting").")
}
