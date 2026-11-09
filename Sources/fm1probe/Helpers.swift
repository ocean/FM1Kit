import FM1Kit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

/// The value after `flag`, e.g. `--repeat 20`.
func option(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Stops fm1probe, reporting failure.
func fail() -> Never {
    exit(1)
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}

/// The time on a 24-hour clock, whatever the locale: under sudo it's often a 12-hour one.
func timestamp() -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: .now)
    let milliseconds = (parts.nanosecond ?? 0) / 1_000_000
    return String(format: "%02d:%02d:%02d.%03d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, milliseconds)
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

/// A flash chip's JEDEC ID and what it means, such as "0xB36014 (UC25HQ80, the newer chip)".
func flashChipDescription(_ id: UInt32) -> String {
    let hexID = String(format: "0x%06X", id)
    switch id {
    case FM1FlashChip.uc25hq80:
        return hexID + " (UC25HQ80, the newer chip: firmwares that don't know it keep saves only until switched off)"
    case FM1FlashChip.p25q80: return hexID + " (P25Q80, the first FM-1s' chip)"
    default: return hexID + " (not a chip FM-1s have)"
    }
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
        printAside("  (other message while waiting: \(hex(reply)))")
    }
    return nil
}
