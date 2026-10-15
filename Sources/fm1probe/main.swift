// A small Mac command-line probe: talk to a real FM-1 over CoreMIDI and inspect .fwsc files.
// It never writes to the device: the only thing it ever sends is the handshake query.

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
    print("Listening on \(connections.map(\.port.name).joined(separator: ", ")) for \(seconds) s. Nothing is sent.")
    let deadline = ContinuousClock.now + .seconds(seconds)
    await withTaskGroup(of: Void.self) { group in
        for connection in connections {
            group.addTask {
                while ContinuousClock.now < deadline {
                    if let message = await connection.receive(timeout: deadline - ContinuousClock.now) {
                        print("\(timestamp())  \(connection.port.name)  \(message.count) bytes  \(hex(message))")
                    }
                    if connection.isLost {
                        print("\(timestamp())  \(connection.port.name)  disconnected")
                        return
                    }
                }
            }
        }
    }
    for connection in connections {
        connection.close()
    }

case "watch":
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 60
    @Sendable func show() async {
        let names = await transport.ports().map { "\($0.name)\(FM1Updater.isProbeable($0) ? "" : " (skipped)")" }
        print("\(timestamp())  \(names.isEmpty ? "no ports" : names.joined(separator: ", "))")
    }
    print("Watching for \(seconds) s. Unplug and replug the FM-1, or switch it off and on.")
    await show()
    let watching = Task {
        for await _ in transport.changes() { await show() }
    }
    try? await Task.sleep(for: .seconds(seconds))
    watching.cancel()

case "inspect" where arguments.count == 2:
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let package = try FwscPackage(data: data)
    print("Product:       \(package.product)")
    print("File size:     \(package.fileBytes.count) bytes")
    print("Logical image: \(package.logicalImage.count) bytes")
    print("SHA-256:       \(package.sha256)")
    if let official = OfficialFirmware.matching(package) {
        print("Official:      \(official.name) (verified)")
    }

default:
    print(usage)
    exit(2)
}
