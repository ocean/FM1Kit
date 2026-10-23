import CoreMIDI
import Foundation
import os

/// MIDI over CoreMIDI, for real devices on iOS and macOS.
///
/// It uses the Universal MIDI Packet event-list API with the MIDI 1.0 protocol, so SysEx travels
/// as type 3 packets and no deprecated packet-list calls are needed. It works with any
/// class-compliant USB-MIDI device: an FM-1 on an iPhone or iPad's USB-C port, on a Lightning
/// device through Apple's camera adapter, or on a Mac.
public final class CoreMIDITransport: MIDITransport, @unchecked Sendable {
    // Sendable: the references below never change after `init`, CoreMIDI's calls on them are
    // thread-safe, and the observer table is guarded by its lock.

    /// The CoreMIDI client that owns every port this transport creates.
    let client: MIDIClientRef
    /// The one output port, shared by every connection.
    let outputPort: MIDIPortRef
    /// Streams to notify when devices come or go, by stream.
    private let observers: OSAllocatedUnfairLock<[UUID: AsyncStream<Void>.Continuation]>

    /// Creates a CoreMIDI client.
    ///
    /// - Parameter clientName: The name other MIDI apps see for this client.
    /// - Throws: ``MIDITransportError/unavailable(_:)`` when CoreMIDI can't create the client or
    ///   its output port.
    public init(clientName: String = "FM1Kit") throws {
        let observers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<Void>.Continuation]())
        var client = MIDIClientRef()
        let status = MIDIClientCreateWithBlock(clientName as CFString, &client) { notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                for continuation in observers.withLock({ Array($0.values) }) {
                    continuation.yield()
                }
            default:
                break
            }
        }
        guard status == noErr else {
            throw MIDITransportError.unavailable("MIDIClientCreate returned \(status)")
        }
        var outputPort = MIDIPortRef()
        let portStatus = MIDIOutputPortCreate(client, "\(clientName) out" as CFString, &outputPort)
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            throw MIDITransportError.unavailable("MIDIOutputPortCreate returned \(portStatus)")
        }
        self.client = client
        self.outputPort = outputPort
        self.observers = observers
    }

    deinit {
        MIDIClientDispose(client)
    }

    /// A stream that yields whenever MIDI devices appear, disappear or change.
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

    /// Every online source paired with its destination: same USB entity first, else same name.
    ///
    /// - Returns: The port pairs, in CoreMIDI's source order.
    public func ports() async -> [MIDIPortDescriptor] {
        let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.filter(Self.isOnline)
        var descriptors: [MIDIPortDescriptor] = []
        for sourceIndex in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(sourceIndex)
            guard Self.isOnline(source) else { continue }
            let entity = Self.entity(of: source)
            let name = Self.name(of: source)
            let destination =
                destinations.first { entity != 0 && Self.entity(of: $0) == entity }
                ?? destinations.first { Self.name(of: $0) == name }
            guard let destination else { continue }
            let id = "\(Self.uniqueID(of: source)):\(Self.uniqueID(of: destination))"
            descriptors.append(MIDIPortDescriptor(id: id, name: name, serialNumber: Self.serialNumber(of: entity)))
        }
        return descriptors
    }

    /// Opens a port pair for sending and receiving SysEx.
    ///
    /// - Parameter port: A pair from ``ports()``.
    /// - Returns: The open connection, which keeps this transport alive until it's released.
    /// - Throws: ``MIDITransportError/portGone`` when the pair has gone, or
    ///   ``MIDITransportError/unavailable(_:)`` when CoreMIDI can't open it.
    public func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection {
        let parts = port.id.split(separator: ":").compactMap { MIDIUniqueID($0) }
        guard parts.count == 2,
            let source = Self.endpoint(withUniqueID: parts[0]),
            let destination = Self.endpoint(withUniqueID: parts[1])
        else {
            throw MIDITransportError.portGone
        }
        return try CoreMIDIConnection(
            port: port,
            transport: self,
            source: source,
            destination: destination,
            sourceID: parts[0],
            destinationID: parts[1]
        )
    }

    // MARK: - CoreMIDI property helpers.

    /// The endpoint's display name, or its plain name, or "Unknown".
    static func name(of object: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name) == noErr, let name {
            return name.takeRetainedValue() as String
        }
        if MIDIObjectGetStringProperty(object, kMIDIPropertyName, &name) == noErr, let name {
            return name.takeRetainedValue() as String
        }
        return "Unknown"
    }

    /// The serial number of the USB device an entity belongs to, if it reports one.
    static func serialNumber(of entity: MIDIEntityRef) -> String? {
        var device = MIDIDeviceRef()
        guard entity != 0, MIDIEntityGetDevice(entity, &device) == noErr else { return nil }
        var value: Unmanaged<CFString>?
        // The USB-MIDI driver sets this property; CoreMIDI has no named constant for it.
        guard MIDIObjectGetStringProperty(device, "SerialNumber" as CFString, &value) == noErr, let value else {
            return nil
        }
        let serial = value.takeRetainedValue() as String
        return serial.isEmpty ? nil : serial
    }

    /// The object's unique ID, or 0 when it has none.
    static func uniqueID(of object: MIDIObjectRef) -> MIDIUniqueID {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &value) == noErr else { return 0 }
        return value
    }

    /// False when CoreMIDI marks the endpoint offline.
    static func isOnline(_ endpoint: MIDIEndpointRef) -> Bool {
        var offline: Int32 = 0
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline) == noErr else { return true }
        return offline == 0
    }

    /// The entity (for USB devices, the device's interface) an endpoint belongs to, or 0.
    static func entity(of endpoint: MIDIEndpointRef) -> MIDIEntityRef {
        var entity = MIDIEntityRef()
        guard MIDIEndpointGetEntity(endpoint, &entity) == noErr else { return 0 }
        return entity
    }

    /// The source or destination with this unique ID, if it still exists.
    static func endpoint(withUniqueID id: MIDIUniqueID) -> MIDIEndpointRef? {
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(id, &object, &type) == noErr,
            [.source, .destination, .externalSource, .externalDestination].contains(type)
        else {
            return nil
        }
        return object
    }
}

/// One open port pair.
///
/// Each connection has its own input port, so received SysEx goes straight to its inbox.
final class CoreMIDIConnection: MIDIConnection, @unchecked Sendable {
    // Sendable: every stored property is immutable after `init` or guarded by a lock, and
    // CoreMIDI's send and dispose calls are thread-safe.

    let port: MIDIPortDescriptor
    /// Kept so the client and output port outlive this connection.
    private let transport: CoreMIDITransport
    private let destination: MIDIEndpointRef
    private let sourceID: MIDIUniqueID
    private let destinationID: MIDIUniqueID
    private let inputPort: MIDIPortRef
    private let inbox: SysexInbox
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    /// The most words one event packet carries.
    private static let wordsPerEventPacket = 64

    /// Opens an input port connected to `source`; sending goes to `destination`.
    init(
        port: MIDIPortDescriptor,
        transport: CoreMIDITransport,
        source: MIDIEndpointRef,
        destination: MIDIEndpointRef,
        sourceID: MIDIUniqueID,
        destinationID: MIDIUniqueID
    ) throws {
        // The receive block runs on CoreMIDI's own thread, one call at a time, so the assembler
        // is only ever touched from there.
        let inbox = SysexInbox()
        let assembler = AssemblerBox()
        let receive: MIDIReceiveBlock = { eventList, _ in
            for packet in eventList.unsafeSequence() {
                for message in assembler.consume(packet) {
                    inbox.deliver(message)
                }
            }
        }
        var inputPort = MIDIPortRef()
        let status = MIDIInputPortCreateWithProtocol(
            transport.client, "FM-1 in" as CFString, ._1_0, &inputPort, receive)
        guard status == noErr else {
            throw MIDITransportError.unavailable("MIDIInputPortCreateWithProtocol returned \(status)")
        }
        let connectStatus = MIDIPortConnectSource(inputPort, source, nil)
        guard connectStatus == noErr else {
            MIDIPortDispose(inputPort)
            throw MIDITransportError.unavailable("MIDIPortConnectSource returned \(connectStatus)")
        }
        self.port = port
        self.transport = transport
        self.destination = destination
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.inputPort = inputPort
        self.inbox = inbox
    }

    deinit {
        close()
    }

    var isLost: Bool {
        guard let source = CoreMIDITransport.endpoint(withUniqueID: sourceID),
            let destination = CoreMIDITransport.endpoint(withUniqueID: destinationID)
        else {
            return true
        }
        return !CoreMIDITransport.isOnline(source) || !CoreMIDITransport.isOnline(destination)
    }

    func send(_ sysex: [UInt8]) throws {
        guard !isClosed.withLock({ $0 }) else { throw MIDITransportError.portGone }
        let packets = UMPSysex7.packets(for: sysex)
        // Packets with the same timestamp share event packets of up to 64 words; allow a spare.
        let eventPacketCount = packets.count * 2 / Self.wordsPerEventPacket + 2
        let byteCount = MemoryLayout<MIDIEventList>.size + eventPacketCount * MemoryLayout<MIDIEventPacket>.size

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { buffer.deallocate() }
        let eventList = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        var current: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(eventList, ._1_0)
        for (word0, word1) in packets {
            guard let packet = current else { throw MIDITransportError.sendFailed(-1) }
            var words = (word0, word1)
            current = withUnsafePointer(to: &words) { pair in
                pair.withMemoryRebound(to: UInt32.self, capacity: 2) { words in
                    MIDIEventListAdd(eventList, byteCount, packet, 0, 2, words)
                }
            }
        }
        guard current != nil else { throw MIDITransportError.sendFailed(-1) }

        let status = MIDISendEventList(transport.outputPort, destination, eventList)
        guard status == noErr else { throw MIDITransportError.sendFailed(status) }
    }

    func receive(timeout: Duration) async -> [UInt8]? {
        await inbox.next(timeout: timeout)
    }

    func drain() {
        inbox.drain()
    }

    func close() {
        let wasClosed = isClosed.withLock { closed in
            defer { closed = true }
            return closed
        }
        guard !wasClosed else { return }
        inbox.close()
        MIDIPortDispose(inputPort)
    }
}

/// Holds the SysEx assembler for a connection's receive block.
private final class AssemblerBox: @unchecked Sendable {
    // Sendable: CoreMIDI calls a port's receive block serially, and nothing else touches this.

    private var assembler = UMPSysex7.Assembler()

    /// The complete SysEx messages that end in this event packet.
    func consume(_ packet: UnsafePointer<MIDIEventPacket>) -> [[UInt8]] {
        let wordCount = Int(packet.pointee.wordCount)
        var messages: [[UInt8]] = []
        withUnsafeBytes(of: packet.pointee.words) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            let available = min(wordCount, words.count)
            var index = 0
            while index < available {
                let size = UMPSysex7.wordCount(forFirstWord: words[index])
                if size == 2, words[index] >> 28 == UMPSysex7.messageType, index + 1 < available,
                    let message = assembler.consume(words[index], words[index + 1])
                {
                    messages.append(message)
                }
                index += size
            }
        }
        return messages
    }
}
