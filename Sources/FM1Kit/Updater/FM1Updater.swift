/// A device found on a port, with its connection still open.
public struct FoundDevice: Sendable {
    /// The open connection, which the caller must close when finished with the device.
    public let connection: any MIDIConnection
    /// What the device said it is.
    public let identity: FM1Identity
}

/// Runs the FM-1 USB-MIDI update protocol over any ``MIDITransport``.
///
/// An install goes: handshake, upgrade command, answer staging reads until the device asks for
/// `0xE0000000`, wait for the `ota-` loader, upgrade command again, answer write reads until
/// `0xF0000000`, then wait for the device and check it reports the package's identity. M-VAVE's
/// open firmware is asked about its update support and armed first; see ``FM1Capability``.
///
/// The updater refuses to start while more than one FM-1 answers, and an install that switches the
/// FM-1 to a different firmware needs confirming; see ``check(_:buildID:)``.
///
/// Installs and resumes support cooperative cancellation. Cancelling while the loader is writing
/// leaves the device in its loader, where ``resume(_:events:)`` can finish the update later.
public actor FM1Updater {
    /// Only ports whose names contain one of these are probed, so SysEx is never sent to other gear.
    public static let probeablePortNameFragments = [
        "fm-1", "fm1", "felucca", "ota", "composite", "usb-midi", "simulated",
        // Other firmwares' update loaders, as M-VAVE's updater looks for them.
        "sloop", "clipper", "sinco",
    ]

    /// Where devices are found.
    public let transport: any MIDITransport
    /// How long to wait at each step.
    public let timing: UpdaterTiming

    /// Creates an updater.
    ///
    /// - Parameters:
    ///   - transport: Where to find devices: a ``CoreMIDITransport``, or a ``SimulatedFM1``.
    ///   - timing: How long to wait at each step.
    public init(transport: any MIDITransport, timing: UpdaterTiming = .standard) {
        self.transport = transport
        self.timing = timing
    }

    /// Whether the updater would send SysEx to a port.
    ///
    /// - Parameter port: A port pair from ``MIDITransport/ports()``.
    /// - Returns: `true` when the port's name contains one of ``probeablePortNameFragments``.
    public static func isProbeable(_ port: MIDIPortDescriptor) -> Bool {
        let name = port.name.lowercased()
        return probeablePortNameFragments.contains { name.contains($0) }
    }

    // MARK: - Discovery.

    /// Finds the first probeable port whose device answers the handshake.
    ///
    /// Installs and resumes use ``findAll(where:)`` instead, and refuse to start when more than
    /// one device answers.
    ///
    /// - Parameter filter: Which identities to accept; any by default.
    /// - Returns: The device with its connection left open, or `nil` if none answered.
    public func find(where filter: @Sendable (FM1Identity) -> Bool = { _ in true }) async -> FoundDevice? {
        for port in await transport.ports() where Self.isProbeable(port) {
            guard let connection = try? await transport.open(port) else { continue }
            if let identity = await handshake(connection), filter(identity) {
                return FoundDevice(connection: connection, identity: identity)
            }
            connection.close()
        }
        return nil
    }

    /// Finds every probeable port whose device answers the handshake.
    ///
    /// - Parameter filter: Which identities to accept; any by default.
    /// - Returns: The devices with their connections left open; the caller must close them all.
    public func findAll(where filter: @Sendable (FM1Identity) -> Bool = { _ in true }) async -> [FoundDevice] {
        var found: [FoundDevice] = []
        for port in await transport.ports() where Self.isProbeable(port) {
            guard let connection = try? await transport.open(port) else { continue }
            if let identity = await handshake(connection), filter(identity) {
                found.append(FoundDevice(connection: connection, identity: identity))
            } else {
                connection.close()
            }
        }
        return found
    }

    /// Finds the only device matching `filter`.
    ///
    /// - Returns: The device with its connection left open, or `nil` if none answered.
    /// - Throws: ``FM1UpdateError/multipleDevices(count:)`` when more than one answered.
    func findOnly(where filter: @Sendable (FM1Identity) -> Bool) async throws(FM1UpdateError) -> FoundDevice? {
        let found = await findAll(where: filter)
        guard found.count <= 1 else {
            for device in found {
                device.connection.close()
            }
            throw .multipleDevices(count: found.count)
        }
        return found.first
    }

    /// Asks what the connected FM-1 is running.
    ///
    /// Only the handshake query is sent, so this never changes the device.
    ///
    /// - Returns: What the device reports, or `nil` if no FM-1 answered.
    public func identify() async -> FM1Identity? {
        guard let device = await find() else { return nil }
        device.connection.close()
        return device.identity
    }

    /// Scans until a device matching `filter` answers, or `limit` passes.
    func waitFor(_ limit: Duration, where filter: @escaping @Sendable (FM1Identity) -> Bool) async throws
        -> FoundDevice?
    {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let device = try await findOnly(where: filter) {
                return device
            }
            try await Task.sleep(for: timing.scanInterval)
        }
        return nil
    }

    /// Sends the handshake query and waits for the identity reply, retrying as configured.
    func handshake(_ connection: any MIDIConnection) async -> FM1Identity? {
        connection.drain()
        for _ in 0..<timing.handshakeAttempts {
            guard (try? connection.send(FM1Message.handshakeQuery)) != nil else { return nil }
            let deadline = ContinuousClock.now + timing.handshakeWait
            while ContinuousClock.now < deadline {
                guard let reply = await connection.receive(timeout: deadline - ContinuousClock.now) else { break }
                if let identity = FM1Identity(handshakeReply: reply) {
                    return identity
                }
            }
        }
        return nil
    }

    // MARK: - Installing.

    /// Installs a package on a device that's running firmware (official or custom).
    ///
    /// If the device is already in its loader (an interrupted update, or USB recovery mode), use
    /// ``resume(_:events:)`` instead. An install that switches firmware needs
    /// ``InstallOptions/confirmsSwitchingFirmware``; ``check(_:buildID:)`` says whether it does.
    ///
    /// - Parameters:
    ///   - package: The firmware to install.
    ///   - options: Whether switching firmware is confirmed, and the package's build ID.
    ///   - events: Called with progress as the update goes; it may be called from any task.
    /// - Returns: The identity the device reports once it's running the new firmware.
    /// - Throws: ``FM1UpdateError`` when the update stops or can't start, a ``MIDITransportError``
    ///   when sending fails, or `CancellationError` when the task is cancelled.
    @discardableResult
    public func install(
        _ package: FwscPackage,
        options: InstallOptions = InstallOptions(),
        events: @escaping @Sendable (UpdateEvent) -> Void = { _ in }
    ) async throws -> FM1Identity {
        guard let device = try await findOnly(where: { !$0.isLoader }) else {
            throw FM1UpdateError.deviceNotFound
        }
        let buildID = options.buildID ?? Self.knownBuildID(of: package)
        let staging: ServeOutcome
        do {
            defer { device.connection.close() }
            let check = try await check(package, on: device, buildID: buildID)
            switch check.kind {
            case .reinstall:
                throw FM1UpdateError.alreadyInstalled(device.identity.text)
            case .switchingFirmware where !options.confirmsSwitchingFirmware:
                throw FM1UpdateError.switchNotConfirmed(device: device.identity.text, package: package.product)
            case .sameIdentity where !options.confirmsSameIdentity:
                throw FM1UpdateError.sameIdentityNotConfirmed(device.identity.text)
            case .update, .switchingFirmware, .sameIdentity:
                break
            }
            events(.connected(device.identity))
            if let capability = check.capability {
                try await arm(device.connection, capability: capability, package: package, buildID: buildID)
            }
            try device.connection.send(FM1Message.upgradeCommand)
            try await pause(timing.afterUpgradeCommand)
            staging = try await serve(
                device.connection,
                image: package.logicalImage,
                phase: .staging,
                idleLimit: timing.stagingIdleLimit
            ) { _, requests in
                events(.staging(requests: requests))
            }
        }
        guard staging.finished else {
            if Self.refusedBootloader(staging, of: package) {
                throw FM1UpdateError.bootloaderMismatch(requests: staging.requests)
            }
            throw staging.lost
                ? FM1UpdateError.disconnected(phase: .staging, requests: staging.requests)
                : FM1UpdateError.stalled(phase: .staging, requests: staging.requests)
        }

        events(.waitingForLoader)
        try await Task.sleep(for: timing.loaderBoot)
        // An armed open firmware's loader names the build it was armed with, which must be this one.
        let model = package.identity.model
        let armedPrefix = String((buildID ?? FM1BuildID(knownHex: package.sha256)).hex.prefix(16))
        let isThisUpdate: @Sendable (FM1Identity) -> Bool = { identity in
            identity.isLoader(for: model) && (identity.armedBuildPrefix ?? armedPrefix) == armedPrefix
        }
        guard let loader = try await waitFor(timing.loaderSearch, where: isThisUpdate) else {
            throw FM1UpdateError.loaderNotFound
        }
        return try await write(package, with: loader, expecting: buildID, events: events)
    }

    /// Finishes an update on a device that's waiting in its update loader.
    ///
    /// The loader waits after an interrupted write, and in USB recovery mode: when the FM-1 is
    /// switched on with OCT− held, if its firmware supports that.
    ///
    /// - Parameters:
    ///   - package: The firmware to install.
    ///   - events: Called with progress as the update goes; it may be called from any task.
    /// - Returns: The identity the device reports once it's running the new firmware.
    /// - Throws: ``FM1UpdateError`` when the update stops, a ``MIDITransportError`` when sending
    ///   fails, or `CancellationError` when the task is cancelled.
    @discardableResult
    public func resume(_ package: FwscPackage, events: @escaping @Sendable (UpdateEvent) -> Void = { _ in })
        async throws -> FM1Identity
    {
        guard package.isFirmware else { throw FM1UpdateError.notFirmware(package.product) }
        let model = package.identity.model
        guard let loader = try await findOnly(where: { $0.isLoader(for: model) }) else {
            throw FM1UpdateError.loaderNotFound
        }
        return try await write(package, with: loader, expecting: Self.knownBuildID(of: package), events: events)
    }

    /// Answers the loader's reads, then waits for the device to return running the package, and
    /// checks the build open firmware reports when the package's build ID is known.
    private func write(
        _ package: FwscPackage,
        with loader: FoundDevice,
        expecting buildID: FM1BuildID?,
        events: @escaping @Sendable (UpdateEvent) -> Void
    ) async throws -> FM1Identity {
        let writing: ServeOutcome
        do {
            defer { loader.connection.close() }
            events(.loaderFound(loader.identity))
            try loader.connection.send(FM1Message.upgradeCommand)
            try await pause(timing.afterUpgradeCommand)
            var progress = WriteProgress(region: package.container.applicationRange)
            writing = try await serve(
                loader.connection,
                image: package.logicalImage,
                phase: .writing,
                idleLimit: timing.writeIdleLimit
            ) { request, _ in
                events(progress.record(request))
            }
        }
        guard writing.finished else {
            throw writing.lost
                ? FM1UpdateError.disconnected(phase: .writing, requests: writing.requests)
                : FM1UpdateError.stalled(phase: .writing, requests: writing.requests)
        }

        events(.rebooting)
        try await Task.sleep(for: timing.firmwareBoot)
        guard let returned = try await waitFor(timing.returnSearch, where: { !$0.isLoader }) else {
            throw FM1UpdateError.deviceDidNotReturn
        }
        defer { returned.connection.close() }
        guard returned.identity == package.identity else {
            throw FM1UpdateError.identityMismatch(expected: package.product, reported: returned.identity.text)
        }
        // Stock firmwares can't report their build, so only open firmware's is checked.
        if let buildID, let capability = try? await capability(of: returned), capability.buildID != buildID {
            throw FM1UpdateError.buildMismatch(expected: buildID, reported: capability.buildID)
        }
        events(.finished(returned.identity))
        return returned.identity
    }

    /// True when staging stopped on a read of the package's boot area, as Felucca's platform does
    /// when the FM-1's bootloader isn't the one the package brings: it reads the boot area in
    /// order, comparing each block with the FM-1's, and gives up at the first difference.
    static func refusedBootloader(_ staging: ServeOutcome, of package: FwscPackage) -> Bool {
        guard let boot = package.bootAreaRange, let last = staging.lastRead else { return false }
        return boot.contains(last.lowerBound)
    }

    /// How a run of answering read requests ended.
    struct ServeOutcome {
        /// Image reads answered (finish requests aren't counted).
        var requests = 0
        /// True when the device asked for the expected finish address.
        var finished = false
        /// True when the device disconnected.
        var lost = false
        /// The last read answered.
        var lastRead: Range<Int>?
    }

    /// Answers read requests until the device asks to finish `phase`, goes quiet, or disappears.
    ///
    /// Each reply goes as soon as the device asks: it asks for the next block only when it's
    /// ready, so no pause is needed beyond ``UpdaterTiming/responseDelay`` (none by default).
    ///
    /// - Parameters:
    ///   - connection: The open connection to the device.
    ///   - image: The package's logical image, which the requests address.
    ///   - phase: The half of the update being served, which decides the finish address.
    ///   - idleLimit: How long the device may stay silent before the phase counts as stalled.
    ///   - progress: Called after each answered read with the read and the number of reads so far.
    /// - Returns: How the phase ended: finished, stalled or disconnected, with the reads answered.
    /// - Throws: ``FM1UpdateError/badRequest(address:length:)`` for a request outside the image,
    ///   ``FM1UpdateError/unexpectedFinish(phase:)`` for a request to finish the other half, or
    ///   `CancellationError`.
    func serve(
        _ connection: any MIDIConnection,
        image: [UInt8],
        phase: FM1UpdateError.Phase,
        idleLimit: Duration,
        progress: (FM1ReadRequest, Int) -> Void
    ) async throws -> ServeOutcome {
        let finishAddress = phase == .staging ? FM1Message.stageFinishAddress : FM1Message.writeFinishAddress
        var outcome = ServeOutcome()
        var lastActivity = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            // Checked on every pass: other messages from the device don't count as activity.
            if ContinuousClock.now - lastActivity > idleLimit {
                return outcome
            }
            guard let message = await connection.receive(timeout: .seconds(1)) else {
                if connection.isLost {
                    outcome.lost = true
                    return outcome
                }
                continue
            }
            guard let request = FM1ReadRequest(sysex: message) else { continue }
            lastActivity = ContinuousClock.now

            if request.isFinish {
                guard request.address == finishAddress, request.length == FM1Message.finishPayload.count else {
                    throw FM1UpdateError.unexpectedFinish(phase: phase)
                }
                // The device moves on once it has asked; a lost reply shows up as a failed reconnect.
                try? connection.send(request.finishResponse())
                await settle(connection, answering: request)
                outcome.finished = true
                return outcome
            }
            let start = Int(request.address)
            guard request.length <= FM1Message.maximumReadLength, start + request.length <= image.count else {
                throw FM1UpdateError.badRequest(address: request.address, length: request.length)
            }
            try await pause(timing.responseDelay)
            guard (try? connection.send(request.response(with: image[start..<(start + request.length)]))) != nil else {
                outcome.lost = true
                return outcome
            }
            outcome.requests += 1
            outcome.lastRead = start..<(start + request.length)
            progress(request, outcome.requests)
        }
    }

    /// Keeps a connection open for ``UpdaterTiming/finishSettle`` after a finish reply, answering
    /// any repeat of the request, so closing the port doesn't cut the reply off.
    func settle(_ connection: any MIDIConnection, answering finish: FM1ReadRequest) async {
        let deadline = ContinuousClock.now + timing.finishSettle
        while !connection.isLost, ContinuousClock.now < deadline {
            guard let message = await connection.receive(timeout: deadline - ContinuousClock.now) else { continue }
            if FM1ReadRequest(sysex: message) == finish {
                try? connection.send(finish.finishResponse())
            }
        }
    }

    /// Sleeps for `duration`, or not at all when it's zero.
    func pause(_ duration: Duration) async throws {
        if duration > .zero {
            try await Task.sleep(for: duration)
        }
    }
}
