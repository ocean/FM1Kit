import CoreMIDI
import os

/// Publishes a device's ports as virtual CoreMIDI ports, so other apps can talk to it as they
/// would to a real FM-1: M-UPGRADE, a web updater through Web MIDI, or an updater of your own.
///
/// Give it a ``SimulatedFM1`` to test an updater against an FM-1 that can't be harmed. Each port
/// the device offers becomes a virtual source and destination with the same name; when the device
/// restarts, as an FM-1 does into its update loader, they go away and come back as a USB device's
/// would. Messages travel as MIDI 1.0 SysEx.
///
/// ```swift
/// let fm1 = SimulatedFM1()
/// fm1.prepare(for: package)
/// let published = try CoreMIDIVirtualDevice(publishing: fm1)
/// await published.run()  // until the task is cancelled
/// ```
public final class CoreMIDIVirtualDevice: @unchecked Sendable {
    // Sendable: `client`, `device` and `observer` never change after `init`; `published` is only
    // touched by `run()`, which works through one change at a time, and guarded by its lock.

    /// Told of every message, as it passes: the message, which way it went, and the port's name.
    public typealias Observer =
        @Sendable (_ sysex: [UInt8], _ direction: FM1MessageDescription.Direction, _ port: String)
        -> Void

    /// One port of the device, published.
    private struct Published {
        let source: MIDIEndpointRef
        let destination: MIDIEndpointRef
        let connection: any MIDIConnection
        let forwarding: Task<Void, Never>
    }

    private let client: MIDIClientRef
    private let device: any MIDITransport
    private let observer: Observer?
    private let published = OSAllocatedUnfairLock(initialState: [String: Published]())

    /// Creates the CoreMIDI client that will own the virtual ports.
    ///
    /// - Parameters:
    ///   - device: The device to publish, such as a ``SimulatedFM1``.
    ///   - clientName: The name other MIDI apps see for the client.
    ///   - observer: Told of every message to and from the device.
    /// - Throws: ``MIDITransportError/unavailable(_:)`` when CoreMIDI can't create the client.
    public init(publishing device: any MIDITransport, clientName: String = "FM1Kit", observer: Observer? = nil) throws {
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock(clientName as CFString, &client, nil)
        guard status == noErr else {
            throw MIDITransportError.unavailable("MIDIClientCreate returned \(status)")
        }
        self.client = client
        self.device = device
        self.observer = observer
    }

    deinit {
        for port in published.withLock({ Array($0.values) }) {
            Self.withdraw(port)
        }
        MIDIClientDispose(client)
    }

    /// The names of the ports published now.
    public var portNames: [String] {
        published.withLock { $0.values.map { CoreMIDITransport.name(of: $0.source) } }
    }

    /// Publishes the device's ports, and keeps them in step with it until the task is cancelled,
    /// then withdraws them.
    ///
    /// - Throws: ``MIDITransportError/unavailable(_:)`` when CoreMIDI can't create a port.
    public func run() async throws {
        let changes = device.changes()
        try await synchronise()
        for await _ in changes {
            try await synchronise()
        }
        for port in published.withLock({ state in
            defer { state = [:] }
            return Array(state.values)
        }) {
            Self.withdraw(port)
        }
    }

    /// Withdraws ports the device no longer offers, and publishes new ones.
    private func synchronise() async throws {
        let ports = await device.ports()
        let ids = Set(ports.map(\.id))
        let gone = published.withLock { state in
            let gone = state.filter { !ids.contains($0.key) }
            for id in gone.keys { state[id] = nil }
            return Array(gone.values)
        }
        for port in gone {
            Self.withdraw(port)
        }
        for port in ports where published.withLock({ $0[port.id] }) == nil {
            guard let connection = try? await device.open(port) else { continue }
            let publishedPort = try publish(port, through: connection)
            published.withLock { $0[port.id] = publishedPort }
        }
    }

    /// Creates a virtual source and destination named after `port`, and starts passing messages.
    private func publish(_ port: MIDIPortDescriptor, through connection: any MIDIConnection) throws -> Published {
        let name = port.name
        let observer = observer
        var source = MIDIEndpointRef()
        let sourceStatus = MIDISourceCreateWithProtocol(client, name as CFString, ._1_0, &source)
        guard sourceStatus == noErr else {
            throw MIDITransportError.unavailable("MIDISourceCreateWithProtocol returned \(sourceStatus)")
        }
        // CoreMIDI calls the block on its own thread, one list at a time, so the assembler is
        // only ever touched from there.
        let assembler = AssemblerBox()
        var destination = MIDIEndpointRef()
        let receive: MIDIReceiveBlock = { eventList, _ in
            for packet in eventList.unsafeSequence() {
                for message in assembler.consume(packet) {
                    observer?(message, .toDevice, name)
                    try? connection.send(message)
                }
            }
        }
        let destinationStatus = MIDIDestinationCreateWithProtocol(
            client, name as CFString, ._1_0, &destination, receive)
        guard destinationStatus == noErr else {
            MIDIEndpointDispose(source)
            throw MIDITransportError.unavailable("MIDIDestinationCreateWithProtocol returned \(destinationStatus)")
        }
        let virtualSource = source
        let forwarding = Task {
            while !Task.isCancelled {
                if let message = await connection.receive(timeout: .seconds(1)) {
                    observer?(message, .fromDevice, name)
                    try? CoreMIDIConnection.withEventList(for: message) { MIDIReceivedEventList(virtualSource, $0) }
                } else if connection.isLost {
                    return
                }
            }
        }
        return Published(source: source, destination: destination, connection: connection, forwarding: forwarding)
    }

    /// Stops passing messages and removes the virtual ports, as unplugging a USB device would.
    private static func withdraw(_ port: Published) {
        port.forwarding.cancel()
        port.connection.close()
        MIDIEndpointDispose(port.source)
        MIDIEndpointDispose(port.destination)
    }
}
