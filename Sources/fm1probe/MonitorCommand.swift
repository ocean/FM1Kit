import FM1Kit
import Foundation

/// Listens on every MIDI port for `seconds` and names each SysEx message that arrives; sends nothing.
///
/// - Parameters:
///   - seconds: How long to listen.
///   - logPath: A new CSV file to write every message to, bytes and all, for `replay`.
///   - showsHex: Print every message's bytes, not only those of messages FM1Kit doesn't know.
/// - Throws: When CoreMIDI can't start, or the log can't be created.
func monitor(seconds: Int, logPath: String?, showsHex: Bool) async throws {
    if let logPath, FileManager.default.fileExists(atPath: logPath) {
        stop("\(logPath) already exists. Choose a new name for the log, so an earlier one isn't lost.")
    }
    let transport = try await CoreMIDITransport(clientName: "fm1probe")
    var connections: [any MIDIConnection] = []
    for port in await transport.ports() {
        if let connection = try? await transport.open(port) { connections.append(connection) }
    }
    if connections.isEmpty {
        stop("No MIDI ports to listen on. Is the FM-1 connected and switched on?")
    }
    let log = logPath.map { MessageLog(path: $0, longestLoggedMessage: .max) }
    Style.heading("Listening")
    print("Listening on \(connections.map(\.port.name).joined(separator: ", ")) for \(seconds) s. Nothing is sent.")
    if let logPath { print("Logging every message to \(logPath).") }
    let deadline = ContinuousClock.now + .seconds(seconds)
    let received = await withTaskGroup(of: Int.self) { group in
        for connection in connections {
            group.addTask {
                var count = 0
                while ContinuousClock.now < deadline {
                    if let message = await connection.receive(timeout: deadline - ContinuousClock.now) {
                        count += 1
                        log?.record(message, .fromDevice, port: connection.port.name)
                        let description = FM1MessageDescription(message, direction: .fromDevice)
                        print(Style.logged("\(Style.bold(connection.port.name))  \(description.text)"))
                        if showsHex || isUnknown(description) {
                            print(Style.dim("    \(hex(message))"))
                        }
                    }
                    if connection.isLost {
                        print(
                            Style.logged(
                                "\(Style.bold(connection.port.name))  \(Style.colour("disconnected", .yellow))"))
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
    print("\n" + Style.done("Stopped listening: \(received) SysEx \(received == 1 ? "message" : "messages") received."))
}

/// True for a message FM1Kit can't name, whose bytes are worth showing.
func isUnknown(_ description: FM1MessageDescription) -> Bool {
    ["other", "incomplete"].contains(description.kind) || description.kind.hasPrefix("update command")
}
