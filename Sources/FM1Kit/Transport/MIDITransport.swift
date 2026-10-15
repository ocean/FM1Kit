import Foundation
import os

/// A MIDI input/output pair that might be an FM-1.
public struct MIDIPortDescriptor: Hashable, Sendable, Identifiable {
    /// A stable identifier for the pair while it stays connected.
    public let id: String
    /// The port's name as the system reports it, e.g. "FM-1 Midi".
    public let name: String

    /// Describes a port pair.
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Something that can list MIDI port pairs and open them for SysEx: `CoreMIDITransport` for real
/// devices, or `SimulatedFM1` for the iOS Simulator and tests.
public protocol MIDITransport: AnyObject, Sendable {
    /// Port pairs currently present.
    func ports() async -> [MIDIPortDescriptor]

    /// Opens a pair for sending and receiving SysEx.
    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection

    /// Yields whenever devices appear or disappear.
    func changes() -> AsyncStream<Void>
}

/// An open port pair.
public protocol MIDIConnection: AnyObject, Sendable {
    var port: MIDIPortDescriptor { get }

    /// True once the device behind this connection has gone (unplugged, or rebooted and re-enumerated).
    var isLost: Bool { get }

    /// Sends one complete `F0 ... F7` message.
    func send(_ sysex: [UInt8]) throws

    /// The next complete SysEx message received, or `nil` after `timeout`.
    func receive(timeout: Duration) async -> [UInt8]?

    /// Discards anything received so far.
    func drain()

    func close()
}

/// Why a MIDI connection couldn't be made or used.
public enum MIDITransportError: Error, LocalizedError {
    case unavailable(String)
    case portGone
    case sendFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "MIDI is not available: \(reason)"
        case .portGone:
            return "The MIDI port has gone."
        case .sendFailed(let status):
            return "Sending MIDI failed (OSStatus \(status))."
        }
    }
}

/// A single-consumer queue of received SysEx messages with a timed wait.
public final class SysexInbox: Sendable {
    private struct State {
        var queue: [[UInt8]] = []
        var waiter: CheckedContinuation<[UInt8]?, Never>?
        var waiterToken: UInt64 = 0
        var isClosed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// An empty inbox.
    public init() {}

    /// Called from the MIDI receive thread.
    public func deliver(_ sysex: [UInt8]) {
        let waiter: CheckedContinuation<[UInt8]?, Never>? = state.withLock { state in
            guard !state.isClosed else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.queue.append(sysex)
            return nil
        }
        waiter?.resume(returning: sysex)
    }

    /// The next message, waiting up to `timeout`; `nil` on time-out or once closed.
    public func next(timeout: Duration) async -> [UInt8]? {
        if let queued = state.withLock({ $0.queue.isEmpty ? nil : $0.queue.removeFirst() }) {
            return queued
        }
        enum Outcome {
            case ready([UInt8]?)
            case waiting(UInt64)
        }
        return await withCheckedContinuation { continuation in
            let outcome: Outcome = state.withLock { state in
                if state.isClosed {
                    return .ready(nil)
                }
                if !state.queue.isEmpty {
                    return .ready(state.queue.removeFirst())
                }
                precondition(state.waiter == nil, "SysexInbox supports a single consumer.")
                state.waiterToken &+= 1
                state.waiter = continuation
                return .waiting(state.waiterToken)
            }
            switch outcome {
            case .ready(let message):
                continuation.resume(returning: message)
            case .waiting(let token):
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.expire(token)
                }
            }
        }
    }

    /// Discards messages received so far.
    public func drain() {
        state.withLock { $0.queue.removeAll() }
    }

    /// Wakes any waiter with `nil` and ignores further messages.
    public func close() {
        let waiter = state.withLock { state in
            state.isClosed = true
            state.queue.removeAll()
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: nil)
    }

    private func expire(_ token: UInt64) {
        let waiter = state.withLock { state -> CheckedContinuation<[UInt8]?, Never>? in
            guard state.waiterToken == token, let waiter = state.waiter else { return nil }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: nil)
    }
}
