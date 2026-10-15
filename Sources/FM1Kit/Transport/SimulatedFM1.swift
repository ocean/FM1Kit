import Foundation
import os

/// A software FM-1 that speaks the update protocol, for the iOS Simulator (which cannot see USB
/// MIDI devices) and the tests.
///
/// It behaves like the real device as documented: it answers the handshake, pulls the image
/// with read requests after an upgrade command, reboots into an `ota-` loader between staging
/// and writing, and comes back reporting the installed package's identity. Every response is
/// checked byte for byte against the expected image, so encoding mistakes show up as stalls.
///
/// A real FM-1 learns the image layout from the package header; this one is told the package
/// up front with `prepare(for:)`.
public final class SimulatedFM1: MIDITransport, @unchecked Sendable {
    /// How the simulated device behaves.
    public struct Options: Sendable {
        /// What the simulated device runs when switched on.
        public var installedIdentity = FM1Identity(text: "FM-1_900")!
        /// Start in the update loader, as after holding OCT− at power-on (USB rescue).
        public var startsInRescueMode = false
        /// Reads requested while staging, before the reboot into the loader.
        public var stagingRequestCount = 74
        /// Read size while writing.
        public var writeChunkLength = 512
        /// Device-side pause between requests.
        public var requestInterval: Duration = .milliseconds(4)
        /// How long a reboot takes.
        public var rebootDuration: Duration = .milliseconds(1500)
        /// How long the device waits for each response before giving up.
        public var responseTimeout: Duration = .seconds(5)
        /// Simulate the cable being pulled once the write reaches this fraction (0...1).
        public var unplugDuringWriteAt: Double?

        /// The defaults: an FM-1 running `FM-1_900`, behaving well.
        public init() {}
    }

    enum Mode: Equatable {
        case firmware(FM1Identity)
        case loader
        case offline
    }

    struct State {
        var mode: Mode
        var generation = 0
        var expected: FwscPackage?
        var session: Task<Void, Never>?
        var hasUnpluggedOnce = false
    }

    /// The name of the simulated device's only port.
    public static let portName = "FM-1 Midi (simulated)"
    static let loaderIdentity = FM1Identity(text: "ota-FM-1_009")!

    /// How this device behaves.
    public let options: Options
    let state: OSAllocatedUnfairLock<State>
    private let observers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<Void>.Continuation]())

    /// A log of what the simulated device did, for display.
    public let events = OSAllocatedUnfairLock(initialState: [String]())

    /// A simulated FM-1, switched on.
    public init(options: Options = Options()) {
        self.options = options
        state = OSAllocatedUnfairLock(initialState: State(mode: options.startsInRescueMode ? .loader : .firmware(options.installedIdentity)))
    }

    /// Tells the simulated device which package the host is about to install.
    public func prepare(for package: FwscPackage) {
        state.withLock { $0.expected = package }
    }

    /// What the simulated device would report right now, if it is connected.
    public var currentIdentity: FM1Identity? {
        switch state.withLock({ $0.mode }) {
        case .firmware(let identity): identity
        case .loader: Self.loaderIdentity
        case .offline: nil
        }
    }

    // MARK: - MIDITransport.

    public func ports() async -> [MIDIPortDescriptor] {
        let (mode, generation) = state.withLock { ($0.mode, $0.generation) }
        guard mode != .offline else { return [] }
        return [MIDIPortDescriptor(id: "simulated-\(generation)", name: Self.portName)]
    }

    public func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection {
        let generation = state.withLock { $0.generation }
        guard port.id == "simulated-\(generation)", state.withLock({ $0.mode }) != .offline else {
            throw MIDITransportError.portGone
        }
        return SimulatedConnection(device: self, port: port, generation: generation)
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

    // MARK: - Device behaviour.

    func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation && $0.mode != .offline }
    }

    func handle(_ sysex: [UInt8], from connection: SimulatedConnection) {
        if sysex == FM1Message.handshakeQuery {
            if let identity = currentIdentity {
                connection.toHost.deliver(identity.handshakeReply())
            }
        } else if sysex == FM1Message.upgradeCommand {
            startSession(on: connection)
        } else {
            connection.fromHost.deliver(sysex)
        }
    }

    private func startSession(on connection: SimulatedConnection) {
        state.withLock { state in
            guard state.session == nil, let expected = state.expected else { return }
            let isLoader = state.mode == .loader
            state.session = Task { [weak self] in
                guard let self else { return }
                if isLoader {
                    await self.write(expected, on: connection)
                } else {
                    await self.stage(expected, on: connection)
                }
                self.state.withLock { $0.session = nil }
            }
        }
    }

    private func stage(_ package: FwscPackage, on connection: SimulatedConnection) async {
        let image = package.logicalImage
        let length = min(FM1Message.maximumReadLength, image.count)
        for index in 0..<options.stagingRequestCount {
            let address = (index * length) % max(image.count - length, 1)
            let request = FM1ReadRequest(address: UInt32(address), length: length)
            guard await exchange(request, expecting: Array(image[address..<(address + length)]), on: connection) else { return }
        }
        guard await exchange(FM1ReadRequest(address: FM1Message.stageFinishAddress, length: 8), expecting: FM1Message.finishPayload, on: connection) else { return }
        log("Staged \(package.product); rebooting into the loader.")
        await reboot(into: .loader)
    }

    private func write(_ package: FwscPackage, on connection: SimulatedConnection) async {
        let image = package.logicalImage
        var address = 0
        while address < image.count {
            let length = min(options.writeChunkLength, image.count - address)
            if let unplugAt = options.unplugDuringWriteAt,
               Double(address) / Double(image.count) >= unplugAt,
               !state.withLock({ $0.hasUnpluggedOnce }) {
                state.withLock { $0.hasUnpluggedOnce = true }
                log("Cable pulled at \(Int(unplugAt * 100))%; the loader stays in update mode.")
                await reboot(into: .loader)
                return
            }
            let request = FM1ReadRequest(address: UInt32(address), length: length)
            guard await exchange(request, expecting: Array(image[address..<(address + length)]), on: connection) else { return }
            address += length
        }
        guard await exchange(FM1ReadRequest(address: FM1Message.writeFinishAddress, length: 8), expecting: FM1Message.finishPayload, on: connection) else { return }
        log("Wrote \(package.product); rebooting.")
        await reboot(into: .firmware(package.identity))
    }

    /// Sends one request and checks the host's answer.
    private func exchange(_ request: FM1ReadRequest, expecting expected: [UInt8], on connection: SimulatedConnection) async -> Bool {
        try? await Task.sleep(for: options.requestInterval)
        guard isCurrent(connection.generation) else { return false }
        connection.toHost.deliver(request.encoded())
        while let reply = await connection.fromHost.next(timeout: options.responseTimeout) {
            guard let (answered, data) = FM1ReadRequest.parseResponse(reply) else { continue }
            guard answered.address == request.address, data == expected else {
                log("Bad response at 0x\(String(request.address, radix: 16)); the device stops.")
                return false
            }
            return true
        }
        log("No response at 0x\(String(request.address, radix: 16)); the device stops.")
        return false
    }

    private func reboot(into mode: Mode) async {
        state.withLock { state in
            state.mode = .offline
            state.generation += 1
        }
        notifyObservers()
        try? await Task.sleep(for: options.rebootDuration)
        state.withLock { state in
            state.mode = mode
            state.generation += 1
        }
        notifyObservers()
    }

    private func notifyObservers() {
        for continuation in observers.withLock({ Array($0.values) }) {
            continuation.yield()
        }
    }

    private func log(_ text: String) {
        events.withLock { $0.append(text) }
    }
}

final class SimulatedConnection: MIDIConnection, @unchecked Sendable {
    let port: MIDIPortDescriptor
    let generation: Int
    let toHost = SysexInbox()
    let fromHost = SysexInbox()
    private weak var device: SimulatedFM1?

    init(device: SimulatedFM1, port: MIDIPortDescriptor, generation: Int) {
        self.device = device
        self.port = port
        self.generation = generation
    }

    var isLost: Bool {
        !(device?.isCurrent(generation) ?? false)
    }

    func send(_ sysex: [UInt8]) throws {
        guard let device, device.isCurrent(generation) else { throw MIDITransportError.portGone }
        device.handle(sysex, from: self)
    }

    func receive(timeout: Duration) async -> [UInt8]? {
        await toHost.next(timeout: timeout)
    }

    func drain() {
        toHost.drain()
    }

    func close() {
        toHost.close()
    }
}
