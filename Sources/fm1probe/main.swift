// A small Mac command-line probe: talk to a real FM-1 over CoreMIDI and inspect .fwsc files.
// Only `install` writes to the device, and only after the user types YES to confirm;
// every other command sends nothing but the handshake query.

import FM1Kit
import Foundation

let usage = """
    usage: fm1probe ports                      list MIDI port pairs and which would be probed
           fm1probe identify [options]         ask the connected FM-1 what it's running
               --repeat N                      ask N times and report timings and failures
               --port NAME                     ask this port even if its name doesn't look like an FM-1
           fm1probe monitor [SECONDS]          print every SysEx message any port sends (default 30 s);
                                               sends nothing
           fm1probe watch [SECONDS]            print the ports each time devices come or go (default 60 s)
           fm1probe inspect FILE.fwsc          show a package's identity, size and hash
           fm1probe install FILE.fwsc [options]
                                               write a firmware to the FM-1, after asking to confirm
               --resume                        finish an update on an FM-1 waiting in its update loader
               --simulated                     run against a simulated FM-1 instead (writes nothing)
               --log FILE                      write every message to and from the device to a new
                                               CSV file
    """

let arguments = Array(CommandLine.arguments.dropFirst())

/// The value after `flag`, e.g. `--repeat 20`.
func option(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

func timestamp() -> String {
    Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
}

/// A device's answer to the handshake.
struct HandshakeAnswer {
    /// The reply exactly as received.
    var reply: [UInt8]
    /// What the reply says the device is.
    var identity: FM1Identity
    /// How long the reply took.
    var elapsed: Duration
}

/// Sends the handshake query and waits up to a second for the identity reply.
func handshake(_ connection: any MIDIConnection) async -> HandshakeAnswer? {
    connection.drain()
    let start = ContinuousClock.now
    guard (try? connection.send(FM1Message.handshakeQuery)) != nil else { return nil }
    let deadline = start + .seconds(1)
    while ContinuousClock.now < deadline {
        guard let reply = await connection.receive(timeout: deadline - ContinuousClock.now) else { break }
        if let identity = FM1Identity(handshakeReply: reply) {
            return HandshakeAnswer(reply: reply, identity: identity, elapsed: ContinuousClock.now - start)
        }
        print("  (other message while waiting: \(hex(reply)))")
    }
    return nil
}

switch arguments.first {
case "ports":
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let ports = await transport.ports()
    if ports.isEmpty { print("No MIDI port pairs found.") }
    for port in ports {
        print("\(FM1Updater.isProbeable(port) ? "probe" : "skip ")  \(port.name)  [\(port.id)]")
    }

case "identify":
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let repeats = max(option("--repeat").flatMap(Int.init) ?? 1, 1)
    let wanted = option("--port")
    let ports = await transport.ports().filter { port in
        wanted.map { port.name.localizedCaseInsensitiveContains($0) } ?? FM1Updater.isProbeable(port)
    }
    if ports.isEmpty {
        print(
            wanted.map { "No port matches \"\($0)\"." }
                ?? "No port looks like an FM-1. Run `fm1probe ports`, then try --port NAME.")
        exit(1)
    }
    var anyAnswered = false
    for port in ports {
        print("\(port.name):")
        let connection = try await transport.open(port)
        var times: [Double] = []
        var identities: Set<String> = []
        for attempt in 1...repeats {
            if let answer = await handshake(connection) {
                if times.isEmpty { print("  reply: \(hex(answer.reply))") }
                times.append(milliseconds(answer.elapsed))
                identities.insert(answer.identity.text)
            } else if repeats > 1 {
                print("  attempt \(attempt): no answer")
            }
            if repeats > 1 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        connection.close()
        guard !identities.isEmpty else {
            print("  no answer")
            continue
        }
        anyAnswered = true
        for text in identities.sorted() {
            let isLoader = FM1Identity(text: text)?.isLoader == true
            print(
                "  reports: \(text)  (\(isLoader ? "update loader: mid-update or USB recovery" : "firmware running"))")
        }
        if identities.count > 1 { print("  warning: the answers disagreed") }
        let average = times.reduce(0, +) / Double(times.count)
        let fastest = Int((times.min() ?? 0).rounded())
        let slowest = Int((times.max() ?? 0).rounded())
        print("  answered \(times.count) of \(repeats); reply time \(Int(average.rounded())) ms", terminator: "")
        print(" (fastest \(fastest), slowest \(slowest))")
    }
    if !anyAnswered { exit(1) }

case "monitor":
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 30
    var connections: [any MIDIConnection] = []
    for port in await transport.ports() {
        if let connection = try? await transport.open(port) { connections.append(connection) }
    }
    if connections.isEmpty {
        print("No MIDI ports to listen on. Is the FM-1 connected and switched on?")
        exit(1)
    }
    print("Listening on \(connections.map(\.port.name).joined(separator: ", ")) for \(seconds) s. Nothing is sent.")
    let deadline = ContinuousClock.now + .seconds(seconds)
    let received = await withTaskGroup(of: Int.self) { group in
        for connection in connections {
            group.addTask {
                var count = 0
                while ContinuousClock.now < deadline {
                    if let message = await connection.receive(timeout: deadline - ContinuousClock.now) {
                        count += 1
                        print("\(timestamp())  \(connection.port.name)  \(message.count) bytes  \(hex(message))")
                    }
                    if connection.isLost {
                        print("\(timestamp())  \(connection.port.name)  disconnected")
                        return count
                    }
                }
                return count
            }
        }
        var total = 0
        for await count in group { total += count }
        return total
    }
    for connection in connections {
        connection.close()
    }
    print("Stopped listening: \(received) SysEx \(received == 1 ? "message" : "messages") received.")

case "watch":
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 60
    @Sendable func portSummary() async -> String {
        let names = await transport.ports().map { "\($0.name)\(FM1Updater.isProbeable($0) ? "" : " (skipped)")" }
        return names.isEmpty ? "no ports" : names.joined(separator: ", ")
    }
    print("Watching for \(seconds) s. Unplug and replug the FM-1, or switch it off and on.")
    let initial = await portSummary()
    print("\(timestamp())  \(initial)")
    let watching = Task {
        // CoreMIDI sends several notifications for one plug or unplug, so only print real changes.
        var shown = initial
        for await _ in transport.changes() {
            let summary = await portSummary()
            guard summary != shown else { continue }
            print("\(timestamp())  \(summary)")
            shown = summary
        }
    }
    try? await Task.sleep(for: .seconds(seconds))
    watching.cancel()
    print("Stopped watching after \(seconds) s.")

case "inspect" where arguments.count == 2:
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let package = try FwscPackage(data: data)
    print("Product:       \(package.product)")
    print("File size:     \(package.fileBytes.count) bytes")
    print("Logical image: \(package.logicalImage.count) bytes")
    print("SHA-256:       \(package.sha256)")
    print("Contents:      header, parts and checksums all intact")
    let isStockLoader = package.loaderSHA256 == OfficialFirmware.stockLoaderSHA256
    print("Loader:        \(package.loaderSHA256)\(isStockLoader ? " (M-VAVE's, reports ota-FM-1_015)" : "")")
    if let official = OfficialFirmware.matching(package) {
        print("Official:      \(official.name) (verified)")
    }

case "install" where arguments.count >= 2:
    let isResume = arguments.contains("--resume")
    let isSimulated = arguments.contains("--simulated")
    let path = arguments[1]
    let package = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: path)))
    let device: any MIDITransport
    if isSimulated {
        var options = SimulatedFM1.Options()
        options.startsInRecoveryMode = isResume
        let simulated = SimulatedFM1(options: options)
        simulated.prepare(for: package)
        device = simulated
    } else {
        device = try CoreMIDITransport(clientName: "fm1probe")
    }
    let logPath = option("--log")
    if let logPath, FileManager.default.fileExists(atPath: logPath) {
        print("\(logPath) already exists. Choose a new name for the log, so an earlier one isn't lost.")
        exit(1)
    }
    let transport: any MIDITransport =
        try logPath.map { LoggingTransport(device, log: try MessageLog(path: $0)) } ?? device
    let updater = FM1Updater(transport: transport)

    let official = OfficialFirmware.matching(package).map { "  (\($0.name), verified)" } ?? ""
    print("Package:  \(package.product)\(official)")
    guard let current = await updater.identify() else {
        print("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
        exit(1)
    }
    print("Device:   \(current.text)  (\(current.isLoader ? "update loader" : "firmware running"))")
    guard current.hardwareModel == package.identity.model else {
        print("The package is for \(package.identity.model), but the device is \(current.hardwareModel).")
        exit(1)
    }
    guard isResume == current.isLoader else {
        print(
            isResume
                ? "The FM-1 isn't in its update loader, so there's no update to resume. Leave out --resume."
                : "The FM-1 is waiting in its update loader. Run again with --resume to finish the update.")
        exit(1)
    }
    guard current != package.identity else {
        print("The FM-1 is already running \(package.product), and refuses to reinstall it. Choose another package.")
        exit(1)
    }

    if !isSimulated {
        print(
            """

            This writes \(package.product) to the FM-1. Keep the cable connected and the FM-1 switched on
            until it finishes. Ctrl-C stops the install:
            - while staging, the FM-1 should still start normally afterwards;
            - while writing, it waits in its update loader for `fm1probe install \(path) --resume`.

            """)
        print("Type YES to install it, or anything else to stop: ", terminator: "")
        guard readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES" else {
            print("Stopped. Nothing was sent apart from the handshake query.")
            exit(1)
        }
    }

    if let logPath { print("Logging every message to \(logPath).") }
    let report = InstallReport()
    let start = ContinuousClock.now
    let installation = Task {
        isResume
            ? try await updater.resume(package) { report.record($0) }
            : try await updater.install(package) { report.record($0) }
    }
    // Ctrl-C cancels the install, so the updater stops cleanly between requests.
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { installation.cancel() }
    interrupt.resume()

    do {
        let installed = try await installation.value
        report.printSummary(total: ContinuousClock.now - start)
        print("\nInstalled: the FM-1 is running \(installed.text).")
    } catch is CancellationError {
        report.printSummary(total: ContinuousClock.now - start)
        switch report.step {
        case .writing, .checking:
            print("\nStopped while writing. The FM-1 waits in its update loader; finish with --resume.")
        case .rebooting, .finished:
            print("\nStopped after writing. Check what the FM-1 is running with `fm1probe identify`.")
        case .starting, .staging, .waitingForLoader:
            print("\nStopped before writing. Check what the FM-1 is running with `fm1probe identify`.")
        }
        exit(1)
    } catch {
        report.printSummary(total: ContinuousClock.now - start)
        print("\nStopped: \(error.localizedDescription)")
        exit(1)
    }

default:
    print(usage)
    exit(2)
}
