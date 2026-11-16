import FM1Kit
import Foundation
import os

/// Writes every SysEx message to and from the device as a CSV row.
///
/// It's for studying how the FM-1 reads an image: each read request's address and length, and
/// when it arrived. Each row goes straight to the file, so the log is complete even when the
/// install stops early. The file is made with the first message, so a run that finds no FM-1
/// leaves no log behind to block the next one's name.
final class MessageLog: Sendable {
    /// Which way a message went.
    enum Direction: String {
        case toDevice = "out"
        case fromDevice = "in"
    }

    /// Messages longer than this are logged by size only, so image data doesn't swamp an install's log.
    static let longestInstallMessage = 48

    private let longestLoggedMessage: Int

    /// The log's file: not made yet, open, or not made because it couldn't be.
    private enum File {
        case notYet
        case open(FileHandle)
        case failed
    }

    private let path: String
    private let file = OSAllocatedUnfairLock(initialState: File.notYet)
    private let start = ContinuousClock.now

    /// Prepares a log at `path`, made when the first message arrives.
    ///
    /// The caller checks that `path` is new, so an earlier log is never replaced.
    ///
    /// - Parameters:
    ///   - path: Where to write the log.
    ///   - longestLoggedMessage: Longer messages are logged without their bytes.
    init(path: String, longestLoggedMessage: Int = longestInstallMessage) {
        self.path = path
        self.longestLoggedMessage = longestLoggedMessage
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
        file.withLock { file in
            if case .notYet = file {
                file = openFile().map(File.open) ?? .failed
            }
            if case .open(let handle) = file {
                handle.write(Data((line + "\n").utf8))
            }
        }
    }

    /// Makes the file and writes the header row, or says on standard error why it couldn't.
    private func openFile() -> FileHandle? {
        guard FileManager.default.createFile(atPath: path, contents: nil),
            let handle = FileHandle(forWritingAtPath: path)
        else {
            FileHandle.standardError.write(
                Data("fm1probe: couldn't create the log \(path); carrying on without it.\n".utf8))
            return nil
        }
        handle.write(Data("seconds,direction,port,kind,flash_type,address,length,size,bytes\n".utf8))
        return handle
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
