import Foundation
import os

/// The simulated FM-1 as a ``MIDITransport``: one port, which goes away while it restarts.
extension SimulatedFM1 {
    /// The device's one port, unless it's restarting.
    ///
    /// - Returns: One port named ``portName``, or none.
    public func ports() async -> [MIDIPortDescriptor] {
        let (mode, generation) = state.withLock { ($0.mode, $0.generation) }
        guard mode != .offline else { return [] }
        return [
            MIDIPortDescriptor(id: "simulated-\(generation)", name: Self.portName, serialNumber: options.serialNumber)
        ]
    }

    /// Opens the device's port.
    ///
    /// - Parameter port: The port from ``ports()``.
    /// - Returns: A connection that lasts until the device restarts.
    /// - Throws: ``MIDITransportError/portGone`` if the device has restarted since `port` was listed.
    public func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection {
        let generation = state.withLock { $0.generation }
        guard port.id == "simulated-\(generation)", state.withLock({ $0.mode }) != .offline else {
            throw MIDITransportError.portGone
        }
        return SimulatedConnection(device: self, port: port, generation: generation)
    }

    /// Reports each time the device disconnects or reconnects as it restarts.
    ///
    /// - Returns: A stream that ends when the caller stops iterating it.
    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let observers = observers
        return AsyncStream { continuation in
            observers.withLock { $0[id] = continuation }
            continuation.onTermination = { _ in
                observers.withLock { $0[id] = nil }
            }
        }
    }
}
