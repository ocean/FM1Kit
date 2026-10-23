import Foundation
import os

/// A software FM-1 that speaks the update protocol, for the iOS Simulator (which can't see USB
/// MIDI devices) and tests.
///
/// It behaves like the real device as documented: it answers the handshake, pulls the image
/// with read requests after an upgrade command, restarts into an `ota-` loader between staging
/// and writing, and comes back reporting the installed package's identity. Running V15, it
/// refuses a package with V15's own identity, as V15 is believed to. Running M-VAVE's open
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
        /// While running V15, refuse a package with its own identity, as V15 is believed to.
        ///
        /// Custom firmwares accept their own identity, as Felucca's update code does.
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
        /// The build open firmware reports at first; after an install, the armed or known build.
        public var installedBuildID = FM1BuildID(bytes: [UInt8](repeating: 0, count: FM1BuildID.byteCount))
        /// The updater state open firmware reports: 0 when ready, anything else when busy.
        public var capabilityState = 0
        /// Open firmware's answer to an arming request: 0 accepts it.
        public var armReply: UInt8 = 0
        /// The voice banks V15 starts with: 16 KB, or a pattern standing for an earlier
        /// firmware's leftovers when `nil`.
        public var initialVoices: [UInt8]?
        /// V15's answer to each voice erase or write: 0 accepts it.
        public var voiceReply: UInt8 = 0
        /// Stop answering voice erases and writes after this many, as if the cable were pulled.
        public var stopsAnsweringVoicesAfter: Int?
        /// Open firmware's saved project slots, by index from 0; the others are empty.
        public var projectSlots: [Int: ProjectSlot] = [:]
        /// Open firmware's workspace: the project being edited.
        public var workspace = OpenFirmwareProject.sampleWorkspace
        /// The slot open firmware's workspace was loaded from, from 0.
        public var currentSlot = 0
        /// Open firmware's sample bank, or `nil` when it's empty.
        public var sampleBank: [UInt8]?
        /// The sample bank state open firmware reports while it has one: 2 when it's ready.
        public var sampleState: UInt8 = 2
        /// Stop answering project library requests after this many, as if the cable were pulled.
        public var stopsAnsweringLibraryAfter: Int?
        /// The USB serial number the device reports, or `nil` for none, as Felucca reports.
        public var serialNumber: String? = "SIMULATED-FM-1"
        /// The m-bootloader version installed at first, or `nil` for M-VAVE's bootloader.
        public var bootloaderVersion: String?

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
        /// V15's four voice banks.
        var voices: [UInt8]
        /// Voice erases and writes answered so far.
        var voiceSteps = 0
        /// Open firmware's project library.
        var library: LibraryState
        /// The m-bootloader version installed, or `nil` for M-VAVE's bootloader.
        var bootloaderVersion: String?
    }

    /// The name of the simulated device's only port.
    public static let portName = "FM-1 Midi (simulated)"
    /// What the update loader reports.
    static let loaderIdentity = FM1Identity(model: "ota-FM-1", version: 9)

    /// How this device behaves.
    public let options: Options
    let state: OSAllocatedUnfairLock<State>
    let observers = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<Void>.Continuation]())

    private let eventLog = OSAllocatedUnfairLock(initialState: [String]())

    /// What the simulated device has done so far, oldest first, for display.
    public var events: [String] {
        eventLog.withLock { $0 }
    }

    /// A simulated FM-1, switched on.
    public init(options: Options = Options()) {
        self.options = options
        let mode: Mode = options.startsInRecoveryMode ? .loader : .firmware(options.installedIdentity)
        let voices =
            options.initialVoices
            ?? (0..<FwscPackage.factoryVoicesLength).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let library = LibraryState(workspace: options.workspace, currentSlot: options.currentSlot)
        var initial = State(mode: mode, buildID: options.installedBuildID, voices: voices, library: library)
        initial.bootloaderVersion = options.bootloaderVersion
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    /// Tells the simulated device which package the host is about to install.
    ///
    /// - Parameter package: The package the host will serve; the device checks every response
    ///   against it.
    public func prepare(for package: FwscPackage) {
        state.withLock { $0.expected = package }
    }

    /// The simulated V15's four voice banks.
    public var currentVoices: [UInt8] {
        state.withLock { $0.voices }
    }

    /// The m-bootloader version the simulated FM-1 has, or `nil` for M-VAVE's bootloader.
    public var installedBootloaderVersion: String? {
        state.withLock { $0.bootloaderVersion }
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
        } else if let request = ProjectLibraryMessage.parse(sysex) {
            handleLibraryRequest(request, from: connection)
        } else if let (command, payload) = FM1Message.parseCommand(sysex),
            command == FM1Message.voiceEraseCommand || command == FM1Message.voiceWriteCommand
        {
            handleVoiceCommand(command, payload: payload, from: connection)
        } else {
            connection.fromHost.deliver(sysex)
        }
    }

    /// Starts staging or writing, depending on whether the loader is running.
    private func startSession(on connection: SimulatedConnection) {
        state.withLock { state in
            guard state.session == nil, let expected = state.expected else { return }
            let isLoader = state.mode == .loader
            let generation = state.generation
            state.session = Task { [weak self] in
                guard let self else { return }
                if isLoader {
                    await write(expected, on: connection)
                } else {
                    await stage(expected, on: connection)
                }
                self.state.withLock { if $0.generation == generation { $0.session = nil } }
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
        if options.refusesRunningFirmware, currentIdentity == package.identity, currentIdentity == .officialV15 {
            log("\(package.product) is already running, so the package is refused.")
            return
        }
        let finish = FM1ReadRequest(address: FM1Message.stageFinishAddress, length: 8)
        guard await exchange(finish, expecting: FM1Message.finishPayload, on: connection) else { return }
        guard package.isFirmware else {
            await runInstaller(package)
            return
        }
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
        state.withLock { state in
            state.buildID = state.armedBuildID ?? packageBuildID
            // V15's package writes the whole boot area, putting M-VAVE's bootloader back.
            if package.identity == .officialV15 { state.bootloaderVersion = nil }
        }
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
    func reboot(into mode: Mode) async {
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
            // The rebooting session is over (its task mustn't clear the next), so the next can start.
            state.session = nil
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
    func log(_ text: String) {
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
