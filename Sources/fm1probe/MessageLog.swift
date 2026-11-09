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

    /// Messages longer than this are logged by size only, so image data doesn't swamp an install's log.
    static let longestInstallMessage = 48

    private let longestLoggedMessage: Int

    private let handle: FileHandle
    private let writing = OSAllocatedUnfairLock()
    private let start = ContinuousClock.now

    /// Creates the file and writes the header row.
    ///
    /// The caller checks that `path` is new, so an earlier log is never replaced.
    ///
    /// - Parameters:
    ///   - path: Where to write the log.
    ///   - longestLoggedMessage: Longer messages are logged without their bytes.
    /// - Throws: When the file can't be created.
    init(path: String, longestLoggedMessage: Int = longestInstallMessage) throws {
        self.longestLoggedMessage = longestLoggedMessage
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
        let kind = FM1MessageDescription(sysex, direction: direction == .toDevice ? .toDevice : .fromDevice).kind
        var request = ",,"
        if direction == .fromDevice, let read = FM1ReadRequest(sysex: sysex) {
            request = "\(read.flashType),\(String(format: "0x%08X", read.address)),\(read.length)"
        }
        let bytes = sysex.count <= longestLoggedMessage ? hex(sysex) : ""
        write("\(elapsed),\(direction.rawValue),\"\(port)\",\(kind),\(request),\(sysex.count),\(bytes)")
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
