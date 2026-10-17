import Foundation
import os

/// A software FM-1 that speaks the update protocol, for the iOS Simulator (which can't see USB
/// MIDI devices) and tests.
///
/// It behaves like the real device as documented: it answers the handshake, pulls the image
/// with read requests after an upgrade command, restarts into an `ota-` loader between staging
/// and writing, and comes back reporting the installed package's identity. Like the real
/// device, it refuses a package with the identity it's already running. Running M-VAVE's open
/// firmware (an identity such as `FM-1_8000012`), it answers the capability query and ignores the
/// upgrade command until it's armed; once armed, its loader reports the build, as in
/// `ota-FM1C_db1642b2b6fa5c2c`. Every response is
/// checked byte for byte against the expected image, so encoding mistakes show up as stalls.
///
/// A real FM-1 learns the image layout from the package header; this one is told the package
/// up front with ``prepare(for:)``.
public final class SimulatedFM1: MIDITransport, Sendable {
    /// How the simulated device behaves.
    public struct Options: Sendable {
        /// What the simulated device runs when switched on.
        public var installedIdentity = FM1Identity(model: "FM-1", version: 900)
        /// Start in the update loader, as after holding OCT− at power-on with a firmware that
        /// supports USB recovery mode.
        public var startsInRecoveryMode = false
        /// Refuse a package with the identity already running, as the real device refuses to
        /// reinstall the firmware it's running.
        public var refusesRunningFirmware = true
        /// Reads requested while staging, before the reboot into the loader.
        public var stagingRequestCount = 74
        /// Read size while writing.
        public var writeChunkLength = 512
        /// Read the image from the end backwards while writing, as M-VAVE's V15 loader does.
        public var writesBackwards = false
        /// Read the whole image a second time after writing, as Felucca's loader does (probably
        /// to check what it wrote).
        public var checksAfterWriting = false
        /// Device-side pause between requests.
        public var requestInterval: Duration = .milliseconds(4)
        /// How long a reboot takes.
        public var rebootDuration: Duration = .milliseconds(1500)
        /// How long the device waits for each response before giving up.
        public var responseTimeout: Duration = .seconds(5)
        /// Simulate the cable being pulled once the write reaches this fraction (0...1).
        public var unplugDuringWriteAt: Double?
        /// The build open firmware reports at first; after an install, it reports the build it
        /// was armed with, or the package's known build ID.
        public var installedBuildID = FM1BuildID(bytes: [UInt8](repeating: 0, count: FM1BuildID.byteCount))
        /// The updater state open firmware reports: 0 when ready, anything else when busy.
        public var capabilityState = 0
        /// Open firmware's answer to an arming request: 0 accepts it.
        public var armReply: UInt8 = 0

        /// The defaults: an FM-1 running `FM-1_900`, with timings like the real device's.
        public init() {}
    }

    /// What the simulated device is doing.
    enum Mode: Equatable {
        case firmware(FM1Identity)
        case loader
        case offline
    }

    /// Everything that changes, guarded by one lock.
    struct State {
        var mode: Mode
        var generation = 0
        var expected: FwscPackage?
        var session: Task<Void, Never>?
        var hasUnpluggedOnce = false
        /// The build open firmware reports.
        var buildID: FM1BuildID
        /// The build open firmware was armed with, until it restarts.
        var armedBuildID: FM1BuildID?
    }

    /// The name of the simulated device's only port.
    public static let portName = "FM-1 Midi (simulated)"
    /// What the update loader reports.
    static let loaderIdentity = FM1Identity(model: "ota-FM-1", version: 9)

    /// How this device behaves.
    public let options: Options
    let state: OSAllocatedUnfairLock<State>
    private let observers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<Void>.Continuation]())

    private let eventLog = OSAllocatedUnfairLock(initialState: [String]())

    /// What the simulated device has done so far, oldest first, for display.
    public var events: [String] {
        eventLog.withLock { $0 }
    }

    /// A simulated FM-1, switched on.
    public init(options: Options = Options()) {
        self.options = options
        let mode: Mode = options.startsInRecoveryMode ? .loader : .firmware(options.installedIdentity)
        state = OSAllocatedUnfairLock(initialState: State(mode: mode, buildID: options.installedBuildID))
    }

    /// Tells the simulated device which package the host is about to install.
    ///
    /// - Parameter package: The package the host will serve; the device checks every response
    ///   against it.
    public func prepare(for package: FwscPackage) {
        state.withLock { $0.expected = package }
    }

    /// The build the simulated open firmware reports.
    public var currentBuildID: FM1BuildID {
        state.withLock { $0.buildID }
    }

    /// What the simulated device would report right now, or `nil` while it's restarting.
    public var currentIdentity: FM1Identity? {
        switch state.withLock({ $0.mode }) {
        case .firmware(let identity): identity
        case .loader:
            // After open firmware is armed, its loader names the build it was armed with.
            state.withLock { $0.armedBuildID }.flatMap { FM1Identity(text: "ota-FM1C_\($0.hex.prefix(16))") }
                ?? Self.loaderIdentity
        case .offline: nil
        }
    }

    // MARK: - MIDITransport.

    /// The device's one port, unless it's restarting.
    ///
    /// - Returns: One port named ``portName``, or none.
    public func ports() async -> [MIDIPortDescriptor] {
        let (mode, generation) = state.withLock { ($0.mode, $0.generation) }
        guard mode != .offline else { return [] }
        return [MIDIPortDescriptor(id: "simulated-\(generation)", name: Self.portName)]
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

    // MARK: - Device behaviour.

    /// True while a connection opened at `generation` still reaches the device.
    func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.generation == generation && $0.mode != .offline }
    }

    /// Reacts to a message the host sent.
    func handle(_ sysex: [UInt8], from connection: SimulatedConnection) {
        if sysex == FM1Message.handshakeQuery {
            if let identity = currentIdentity {
                connection.toHost.deliver(identity.handshakeReply())
            }
        } else if sysex == FM1Message.upgradeCommand {
            if currentIdentity?.isOpenFirmware == true, state.withLock({ $0.armedBuildID }) == nil {
                log("Open firmware ignores the upgrade command until it's armed.")
                return
            }
            startSession(on: connection)
        } else if let (command, payload) = FM1Message.parseCommand(sysex),
            command == FM1Message.capabilityCommand || command == FM1Message.armCommand
        {
            handleOpenFirmwareCommand(command, payload: payload, from: connection)
        } else {
            connection.fromHost.deliver(sysex)
        }
    }

    /// Answers a capability query or arming request, as open firmware does; others ignore them.
    private func handleOpenFirmwareCommand(_ command: UInt8, payload: [UInt8], from connection: SimulatedConnection) {
        guard currentIdentity?.isOpenFirmware == true else { return }
        if command == FM1Message.capabilityCommand {
            let capability = FM1Capability(state: options.capabilityState, buildID: currentBuildID)
            connection.toHost.deliver(FM1Message.command(command, payload: capability.payload()))
            return
        }
        let expectedLength = state.withLock { $0.expected?.logicalImage.count }
        guard
            options.armReply == 0, payload.count == 6 + FM1BuildID.byteCount, payload[0] == 1,
            Int(payload[1]) == FM1Capability.fm1Family,
            Int(FM1Message.readLittleEndian(payload, at: 2, byteCount: 4)) == expectedLength
        else {
            log("Arming refused.")
            connection.toHost.deliver(FM1Message.command(command, payload: [max(options.armReply, 1)]))
            return
        }
        state.withLock { $0.armedBuildID = FM1BuildID(bytes: payload[6...]) }
        log("Armed for build \(FM1BuildID(bytes: payload[6...]).hex.prefix(16)).")
        connection.toHost.deliver(FM1Message.command(command, payload: FM1Capability.armAccepted))
    }

    /// Starts staging or writing, depending on whether the loader is running.
    private func startSession(on connection: SimulatedConnection) {
        state.withLock { state in
            guard state.session == nil, let expected = state.expected else { return }
            let isLoader = state.mode == .loader
            state.session = Task { [weak self] in
                guard let self else { return }
                if isLoader {
                    await write(expected, on: connection)
                } else {
                    await stage(expected, on: connection)
                }
                self.state.withLock { $0.session = nil }
            }
        }
    }

    /// Reads part of the package, then restarts into the loader unless the package is refused.
    private func stage(_ package: FwscPackage, on connection: SimulatedConnection) async {
        let image = package.logicalImage
        let length = min(FM1Message.maximumReadLength, image.count)
        for index in 0..<options.stagingRequestCount {
            let address = (index * length) % max(image.count - length, 1)
            let request = FM1ReadRequest(address: UInt32(address), length: length)
            guard await exchange(request, expecting: Array(image[address..<(address + length)]), on: connection) else {
                return
            }
        }
        if options.refusesRunningFirmware, currentIdentity == package.identity {
            log("\(package.product) is already running, so the package is refused.")
            return
        }
        let finish = FM1ReadRequest(address: FM1Message.stageFinishAddress, length: 8)
        guard await exchange(finish, expecting: FM1Message.finishPayload, on: connection) else { return }
        log("Staged \(package.product); rebooting into the loader.")
        await reboot(into: .loader)
    }

    /// Reads the whole package (in the order the options say, and twice if checking), then
    /// restarts running it.
    private func write(_ package: FwscPackage, on connection: SimulatedConnection) async {
        let image = package.logicalImage
        var addresses = Array(stride(from: 0, to: image.count, by: options.writeChunkLength))
        if options.writesBackwards {
            addresses.reverse()
        }
        let passes = options.checksAfterWriting ? [addresses, addresses] : [addresses]
        for pass in passes {
            for (index, address) in pass.enumerated() {
                if let unplugAt = options.unplugDuringWriteAt,
                    Double(index) / Double(pass.count) >= unplugAt,
                    !state.withLock({ $0.hasUnpluggedOnce })
                {
                    state.withLock { $0.hasUnpluggedOnce = true }
                    log("Cable pulled at \(Int(unplugAt * 100))%; the loader stays in update mode.")
                    await reboot(into: .loader)
                    return
                }
                let length = min(options.writeChunkLength, image.count - address)
                let request = FM1ReadRequest(address: UInt32(address), length: length)
                let expected = Array(image[address..<(address + length)])
                guard await exchange(request, expecting: expected, on: connection) else {
                    return
                }
            }
        }
        let finish = FM1ReadRequest(address: FM1Message.writeFinishAddress, length: 8)
        guard await exchange(finish, expecting: FM1Message.finishPayload, on: connection) else { return }
        log("Wrote \(package.product); rebooting.")
        // Real open firmware reports the build compiled into it: here, the one it was armed with, or
        // else the build ID FM1Kit knows for the package.
        let packageBuildID = FM1Updater.knownBuildID(of: package) ?? FM1BuildID(knownHex: package.sha256)
        state.withLock { $0.buildID = $0.armedBuildID ?? packageBuildID }
        await reboot(into: .firmware(package.identity))
    }

    /// Sends one request and checks the host's answer.
    private func exchange(_ request: FM1ReadRequest, expecting expected: [UInt8], on connection: SimulatedConnection)
        async -> Bool
    {
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

    /// Disappears from the port list, then comes back in `mode`.
    private func reboot(into mode: Mode) async {
        state.withLock { state in
            state.mode = .offline
            state.generation += 1
            // Only the firmware that was armed remembers it, so arming doesn't survive the loader.
            if case .firmware = mode { state.armedBuildID = nil }
        }
        notifyObservers()
        try? await Task.sleep(for: options.rebootDuration)
        state.withLock { state in
            state.mode = mode
            state.generation += 1
        }
        notifyObservers()
    }

    /// Yields to every ``changes()`` stream.
    private func notifyObservers() {
        for continuation in observers.withLock({ Array($0.values) }) {
            continuation.yield()
        }
    }

    /// Adds a line to ``events``.
    private func log(_ text: String) {
        eventLog.withLock { $0.append(text) }
    }
}

/// A connection to the simulated device, which ends when the device restarts.
final class SimulatedConnection: MIDIConnection, @unchecked Sendable {
    // Sendable: `device` is only written in `init`; the inboxes are thread-safe.

    let port: MIDIPortDescriptor
    let generation: Int
    /// Messages from the device, for ``receive(timeout:)``.
    let toHost = SysexInbox()
    /// Responses from the host, for the device's session.
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
