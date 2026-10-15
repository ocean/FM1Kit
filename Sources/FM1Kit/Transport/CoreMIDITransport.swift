import CoreMIDI
import Foundation
import os

/// MIDI over CoreMIDI, using the Universal MIDI Packet event-list API (MIDI 1.0 protocol), so
/// SysEx travels as type 3 packets and needs no deprecated packet-list calls.
///
/// Works with any class-compliant USB-MIDI device: an FM-1 on an iPhone's USB-C port (or
/// Lightning with the Camera Adapter), or on a Mac.
public final class CoreMIDITransport: MIDITransport, @unchecked Sendable {
    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private let observers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<Void>.Continuation]())

    /// Creates a CoreMIDI client. `clientName` is what other MIDI apps see; it throws when
    /// CoreMIDI isn't available.
    public init(clientName: String = "FM1Kit") throws {
        let status = MIDIClientCreateWithBlock(clientName as CFString, &client) { [weak self] notification in
            switch notification.pointee.messageID {
            case .msgSetupChanged, .msgObjectAdded, .msgObjectRemoved, .msgPropertyChanged:
                self?.notifyObservers()
            default:
                break
            }
        }
        guard status == noErr else {
            throw MIDITransportError.unavailable("MIDIClientCreate returned \(status)")
        }
        let portStatus = MIDIOutputPortCreate(client, "\(clientName) out" as CFString, &outputPort)
        guard portStatus == noErr else {
            throw MIDITransportError.unavailable("MIDIOutputPortCreate returned \(portStatus)")
        }
    }

    deinit {
        MIDIClientDispose(client)
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            observers.withLock { $0[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.observers.withLock { $0[id] = nil }
            }
        }
    }

    private func notifyObservers() {
        for continuation in observers.withLock({ Array($0.values) }) {
            continuation.yield()
        }
    }

    /// Every online source paired with its destination: same USB entity first, else same name.
    public func ports() async -> [MIDIPortDescriptor] {
        let destinations = (0..<MIDIGetNumberOfDestinations()).map { MIDIGetDestination($0) }.filter(Self.isOnline)
        var descriptors: [MIDIPortDescriptor] = []
        for sourceIndex in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(sourceIndex)
            guard Self.isOnline(source) else { continue }
            let entity = Self.entity(of: source)
            let name = Self.name(of: source)
            let destination = destinations.first { entity != 0 && Self.entity(of: $0) == entity }
                ?? destinations.first { Self.name(of: $0) == name }
            guard let destination else { continue }
            descriptors.append(MIDIPortDescriptor(
                id: "\(Self.uniqueID(of: source)):\(Self.uniqueID(of: destination))",
                name: name
            ))
        }
        return descriptors
    }

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
            client: client,
            outputPort: outputPort,
            source: source,
            destination: destination,
            sourceID: parts[0],
            destinationID: parts[1]
        )
    }

    // MARK: - CoreMIDI property helpers.

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

    static func uniqueID(of object: MIDIObjectRef) -> MIDIUniqueID {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &value)
        return value
    }

    static func isOnline(_ endpoint: MIDIEndpointRef) -> Bool {
        var offline: Int32 = 0
        MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
        return offline == 0
    }

    static func entity(of endpoint: MIDIEndpointRef) -> MIDIEntityRef {
        var entity = MIDIEntityRef()
        MIDIEndpointGetEntity(endpoint, &entity)
        return entity
    }

    static func endpoint(withUniqueID id: MIDIUniqueID) -> MIDIEndpointRef? {
        var object = MIDIObjectRef()
        var type = MIDIObjectType.other
        guard MIDIObjectFindByUniqueID(id, &object, &type) == noErr,
              type == .source || type == .destination || type == .externalSource || type == .externalDestination
        else {
            return nil
        }
        return object
    }
}

/// One open FM-1 port pair. Each connection has its own input port, so received SysEx goes
/// straight to its inbox.
final class CoreMIDIConnection: MIDIConnection, @unchecked Sendable {
    let port: MIDIPortDescriptor
    private let outputPort: MIDIPortRef
    private let destination: MIDIEndpointRef
    private let sourceID: MIDIUniqueID
    private let destinationID: MIDIUniqueID
    private var inputPort = MIDIPortRef()
    private let inbox = SysexInbox()
    private let isClosed = OSAllocatedUnfairLock(initialState: false)

    init(
        port: MIDIPortDescriptor,
        client: MIDIClientRef,
        outputPort: MIDIPortRef,
        source: MIDIEndpointRef,
        destination: MIDIEndpointRef,
        sourceID: MIDIUniqueID,
        destinationID: MIDIUniqueID
    ) throws {
        self.port = port
        self.outputPort = outputPort
        self.destination = destination
        self.sourceID = sourceID
        self.destinationID = destinationID

        // The receive block runs on CoreMIDI's own thread, one call at a time, so the assembler
        // is only ever touched from there.
        let inbox = inbox
        let assembler = AssemblerBox()
        let status = MIDIInputPortCreateWithProtocol(client, "FM-1 in" as CFString, ._1_0, &inputPort) { eventList, _ in
            for packet in eventList.unsafeSequence() {
                for message in assembler.consume(packet) {
                    inbox.deliver(message)
                }
            }
        }
        guard status == noErr else {
            throw MIDITransportError.unavailable("MIDIInputPortCreateWithProtocol returned \(status)")
        }
        let connectStatus = MIDIPortConnectSource(inputPort, source, nil)
        guard connectStatus == noErr else {
            MIDIPortDispose(inputPort)
            throw MIDITransportError.unavailable("MIDIPortConnectSource returned \(connectStatus)")
        }
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
        let wordsPerEventPacket = 64
        let eventPacketCount = (packets.count * 2) / wordsPerEventPacket + 2
        let byteCount = MemoryLayout<MIDIEventList>.size + eventPacketCount * MemoryLayout<MIDIEventPacket>.size

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { buffer.deallocate() }
        let eventList = buffer.bindMemory(to: MIDIEventList.self, capacity: 1)
        var current: UnsafeMutablePointer<MIDIEventPacket>? = MIDIEventListInit(eventList, ._1_0)
        for (word0, word1) in packets {
            guard let packet = current else { throw MIDITransportError.sendFailed(-1) }
            let words: [UInt32] = [word0, word1]
            current = words.withUnsafeBufferPointer {
                MIDIEventListAdd(eventList, byteCount, packet, 0, 2, $0.baseAddress!)
            }
        }
        guard current != nil else { throw MIDITransportError.sendFailed(-1) }

        let status = MIDISendEventList(outputPort, destination, eventList)
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
    private var assembler = UMPSysex7.Assembler()

    func consume(_ packet: UnsafePointer<MIDIEventPacket>) -> [[UInt8]] {
        let wordCount = Int(packet.pointee.wordCount)
        var messages: [[UInt8]] = []
        withUnsafeBytes(of: packet.pointee.words) { raw in
            let words = raw.bindMemory(to: UInt32.self)
            var index = 0
            while index < min(wordCount, words.count) {
                let size = UMPSysex7.wordCount(forFirstWord: words[index])
                if size == 2, words[index] >> 28 == UMPSysex7.messageType, index + 1 < wordCount,
                   let message = assembler.consume(words[index], words[index + 1]) {
                    messages.append(message)
                }
                index += size
            }
        }
        return messages
    }
}
