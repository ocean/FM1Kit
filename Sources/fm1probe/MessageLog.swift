import FM1Kit
import Foundation
import os

/// Writes every SysEx message to and from the device as a CSV row.
///
/// It's for studying how the FM-1 reads an image: each read request's address and length, and
/// when it arrived. Each row goes straight to the file, so the log is complete even when the
/// install stops early.
final class MessageLog: Sendable {
    /// Which way a message went.
    enum Direction: String {
        case toDevice = "out"
        case fromDevice = "in"
    }

    /// Messages longer than this are logged by size only, so image data doesn't swamp the file.
    static let longestLoggedMessage = 48

    private let handle: FileHandle
    private let writing = OSAllocatedUnfairLock()
    private let start = ContinuousClock.now

    /// Creates the file and writes the header row.
    ///
    /// The caller checks that `path` is new, so an earlier log is never replaced.
    ///
    /// - Parameter path: Where to write the log.
    /// - Throws: When the file can't be created.
    init(path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path])
        }
        handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        write("seconds,direction,port,kind,flash_type,address,length,size,bytes")
    }

    /// Logs one message.
    ///
    /// - Parameters:
    ///   - sysex: The complete `F0 … F7` message.
    ///   - direction: Which way it went.
    ///   - port: The name of the port it went through.
    func record(_ sysex: [UInt8], _ direction: Direction, port: String) {
        let elapsed = String(format: "%.3f", milliseconds(ContinuousClock.now - start) / 1000)
        var kind = "other"
        var request = ",,"
        if direction == .fromDevice, let read = FM1ReadRequest(sysex: sysex) {
            kind = read.isFinish ? "finish" : "read"
            request = "\(read.flashType),\(String(format: "0x%08X", read.address)),\(read.length)"
        } else if direction == .fromDevice, let identity = FM1Identity(handshakeReply: sysex) {
            kind = "identity \(identity.text)"
        } else if sysex == FM1Message.handshakeQuery {
            kind = "handshake"
        } else if sysex == FM1Message.upgradeCommand {
            kind = "upgrade"
        } else if let command = Self.commandName(sysex) {
            kind = command
        } else if direction == .toDevice {
            kind = "response"
        }
        let bytes = sysex.count <= Self.longestLoggedMessage ? hex(sysex) : ""
        write("\(elapsed),\(direction.rawValue),\"\(port)\",\(kind),\(request),\(sysex.count),\(bytes)")
    }

    /// Names open firmware's capability (`0x31`) and arming (`0x32`) messages, and V15's voice
    /// erases (`0x21`), writes (`0x22`) and their acknowledgements (`0x00`), either way.
    static func commandName(_ sysex: [UInt8]) -> String? {
        guard sysex.count > 4, sysex.first == 0xF0, sysex.last == 0xF7 else { return nil }
        // Open firmware's project library: F0 7D 46 4D 02, then the command (bit 6 set in replies).
        if sysex.count > 5, Array(sysex[1...4]) == [0x7D, 0x46, 0x4D, 0x02] {
            let command = sysex[5] & 0x3F
            let names: [UInt8: String] = [
                0: "info", 1: "open read", 2: "read", 3: "open write", 4: "write", 5: "finish write",
                6: "close", 8: "load slot", 9: "slot name", 11: "sample info", 15: "read samples",
            ]
            return "library " + (names[command] ?? "command \(command)") + (sysex[5] & 0x40 != 0 ? " reply" : "")
        }
        let body = SevenBit.unpack(sysex.dropFirst().dropLast())
        guard body.count > 2, body[0] == 0x00, body[1] == 0x59 else { return nil }
        switch body[2] {
        case 0x00: return "acknowledgement"
        case 0x21: return "voice erase"
        case 0x22: return "voice write"
        case 0x31: return "capability"
        case 0x32: return "arm"
        default: return nil
        }
    }

    private func write(_ line: String) {
        writing.withLock { handle.write(Data((line + "\n").utf8)) }
    }
}

/// A transport that logs every message its connections send and receive.
final class LoggingTransport: MIDITransport {
    private let base: any MIDITransport
    private let log: MessageLog

    /// Wraps `base`, logging to `log`.
    init(_ base: any MIDITransport, log: MessageLog) {
        self.base = base
        self.log = log
    }

    func ports() async -> [MIDIPortDescriptor] {
        await base.ports()
    }

    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection {
        LoggingConnection(try await base.open(port), log: log)
    }

    func changes() -> AsyncStream<Void> {
        base.changes()
    }
}

/// A connection that logs every message it sends and receives.
final class LoggingConnection: MIDIConnection {
    private let base: any MIDIConnection
    private let log: MessageLog

    var port: MIDIPortDescriptor { base.port }
    var isLost: Bool { base.isLost }

    /// Wraps `base`, logging to `log`.
    init(_ base: any MIDIConnection, log: MessageLog) {
        self.base = base
        self.log = log
    }

    func send(_ sysex: [UInt8]) throws {
        log.record(sysex, .toDevice, port: port.name)
        try base.send(sysex)
    }

    func receive(timeout: Duration) async -> [UInt8]? {
        let message = await base.receive(timeout: timeout)
        if let message {
            log.record(message, .fromDevice, port: port.name)
        }
        return message
    }

    func drain() {
        base.drain()
    }

    func close() {
        base.close()
    }
}
