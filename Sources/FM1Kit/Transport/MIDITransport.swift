public import Foundation
import os

/// A MIDI input/output pair that might be an FM-1.
public struct MIDIPortDescriptor: Hashable, Sendable, Identifiable {
    /// A stable identifier for the pair while it stays connected.
    public let id: String
    /// The port's name as the system reports it, e.g. "FM-1 Midi".
    public let name: String
    /// The USB device's serial number, when its firmware reports one.
    ///
    /// M-VAVE's V15 and open firmware report the same number for a unit, so it can tell one
    /// FM-1 from another; Felucca reports none.
    public let serialNumber: String?

    /// Describes a port pair.
    ///
    /// - Parameters:
    ///   - id: An identifier the transport can open the pair by.
    ///   - name: The name to show and to match against ``FM1Updater/probeablePortNameFragments``.
    ///   - serialNumber: The USB device's serial number, if it reports one.
    public init(id: String, name: String, serialNumber: String? = nil) {
        self.id = id
        self.name = name
        self.serialNumber = serialNumber
    }
}

/// Something that can list MIDI port pairs and open them for SysEx.
///
/// Use ``CoreMIDITransport`` for real devices, or ``SimulatedFM1`` for the iOS Simulator and
/// tests. Conform to it to carry the protocol over something else.
public protocol MIDITransport: AnyObject, Sendable {
    /// Lists the port pairs present now.
    ///
    /// - Returns: Every pair, whether or not it looks like an FM-1.
    func ports() async -> [MIDIPortDescriptor]

    /// Opens a pair for sending and receiving SysEx.
    ///
    /// - Parameter port: A pair from ``ports()``.
    /// - Returns: The open connection.
    /// - Throws: A ``MIDITransportError`` when the pair has gone or can't be opened.
    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection

    /// Reports when devices appear, disappear or change.
    ///
    /// - Returns: A stream that yields on each change, until the caller stops iterating it.
    func changes() -> AsyncStream<Void>
}

/// An open port pair.
public protocol MIDIConnection: AnyObject, Sendable {
    /// The pair this connection is open on.
    var port: MIDIPortDescriptor { get }

    /// True once the device behind this connection has gone (unplugged, or restarted and
    /// re-enumerated).
    var isLost: Bool { get }

    /// Sends one message.
    ///
    /// - Parameter sysex: A complete `F0 … F7` message.
    /// - Throws: A ``MIDITransportError`` when the connection is closed or sending fails.
    func send(_ sysex: [UInt8]) throws

    /// Waits for the next complete SysEx message.
    ///
    /// - Parameter timeout: How long to wait.
    /// - Returns: The message, or `nil` on time-out or once the connection is closed.
    func receive(timeout: Duration) async -> [UInt8]?

    /// Discards anything received so far.
    func drain()

    /// Closes the connection. Calling it again does nothing.
    func close()
}

/// Why a MIDI connection couldn't be made or used.
public enum MIDITransportError: Error, Hashable, LocalizedError {
    /// The system couldn't provide MIDI; the text says which call failed.
    case unavailable(String)
    /// The port pair has gone, or the connection is closed.
    case portGone
    /// Sending failed with this CoreMIDI status.
    case sendFailed(OSStatus)

    /// What went wrong, in words suitable for a log or an alert.
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            "MIDI isn't available: \(reason)."
        case .portGone:
            "The MIDI port has gone."
        case .sendFailed(let status):
            "Sending MIDI failed (OSStatus \(status))."
        }
    }
}

/// A single-consumer queue of received SysEx messages with a timed wait.
///
/// A transport's receive callback calls ``deliver(_:)`` from its own thread; one task at a time
/// reads with ``next(timeout:)``. Conforming transports can use it to implement
/// ``MIDIConnection/receive(timeout:)``.
public final class SysexInbox: Sendable {
    /// The most messages kept unread; when it's full, the oldest is dropped.
    public static let capacity = 256

    private struct Waiter {
        var token: UInt64
        var continuation: CheckedContinuation<[UInt8]?, Never>
    }

    private struct State {
        var queue: [[UInt8]] = []
        var waiter: Waiter?
        var lastToken: UInt64 = 0
        /// A wait cancelled before it started waiting, so it ends at once.
        var cancelledToken: UInt64?
        var isClosed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Creates an empty inbox.
    public init() {}

    /// Adds a received message, waking the reader if it's waiting.
    ///
    /// Messages delivered after ``close()`` are ignored.
    ///
    /// - Parameter sysex: A complete `F0 … F7` message.
    public func deliver(_ sysex: [UInt8]) {
        let waiter: Waiter? = state.withLock { state in
            guard !state.isClosed else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            if state.queue.count >= Self.capacity {
                state.queue.removeFirst()
            }
            state.queue.append(sysex)
            return nil
        }
        waiter?.continuation.resume(returning: sysex)
    }

    /// Waits for the next message.
    ///
    /// Only one task may wait at a time.
    ///
    /// - Parameter timeout: How long to wait.
    /// - Returns: The oldest unread message, or `nil` on time-out, on cancellation, or once closed.
    public func next(timeout: Duration) async -> [UInt8]? {
        let token = state.withLock { state in
            state.lastToken &+= 1
            return state.lastToken
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: [UInt8]?? = state.withLock { state in
                    if !state.queue.isEmpty {
                        return .some(state.queue.removeFirst())
                    }
                    if state.isClosed || state.cancelledToken == token {
                        return .some(nil)
                    }
                    precondition(state.waiter == nil, "SysexInbox supports a single reader.")
                    state.waiter = Waiter(token: token, continuation: continuation)
                    return nil
                }
                if let ready {
                    continuation.resume(returning: ready)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.expire(token)
                }
            }
        } onCancel: {
            expire(token, cancelling: true)
        }
    }

    /// Discards unread messages.
    public func drain() {
        state.withLock { $0.queue.removeAll() }
    }

    /// Wakes any waiting reader with `nil` and ignores later messages.
    public func close() {
        let waiter: Waiter? = state.withLock { state in
            state.isClosed = true
            state.queue.removeAll()
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.continuation.resume(returning: nil)
    }

    /// Ends the wait with this token, if it's still waiting; a cancellation that arrives before
    /// the wait starts is remembered so the wait ends at once.
    private func expire(_ token: UInt64, cancelling: Bool = false) {
        let waiter: Waiter? = state.withLock { state in
            guard let waiter = state.waiter, waiter.token == token else {
                if cancelling { state.cancelledToken = token }
                return nil
            }
            state.waiter = nil
            return waiter
        }
        waiter?.continuation.resume(returning: nil)
    }
}
