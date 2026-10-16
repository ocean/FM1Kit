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
/// `0xF0000000`, then wait for the device and check it reports the package's identity.
///
/// Installs and resumes support cooperative cancellation. Cancelling while the loader is writing
/// leaves the device in its loader, where ``resume(_:events:)`` can finish the update later.
public actor FM1Updater {
    /// Only ports whose names contain one of these are probed, so SysEx is never sent to other gear.
    public static let probeablePortNameFragments = [
        "fm-1", "fm1", "felucca", "ota", "composite", "usb-midi", "simulated",
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
            if let device = await find(where: filter) {
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
    /// ``resume(_:events:)`` instead.
    ///
    /// - Parameters:
    ///   - package: The firmware to install.
    ///   - events: Called with progress as the update goes; it may be called from any task.
    /// - Returns: The identity the device reports once it's running the new firmware.
    /// - Throws: ``FM1UpdateError`` when the update stops, a ``MIDITransportError`` when sending
    ///   fails, or `CancellationError` when the task is cancelled.
    @discardableResult
    public func install(_ package: FwscPackage, events: @escaping @Sendable (UpdateEvent) -> Void = { _ in })
        async throws -> FM1Identity
    {
        guard let device = await find(where: { !$0.isLoader }) else {
            throw FM1UpdateError.deviceNotFound
        }
        let staging: ServeOutcome
        do {
            defer { device.connection.close() }
            guard device.identity.hardwareModel == package.identity.model else {
                throw FM1UpdateError.modelMismatch(device: device.identity.text, package: package.product)
            }
            events(.connected(device.identity))
            try device.connection.send(FM1Message.upgradeCommand)
            try await Task.sleep(for: timing.afterUpgradeCommand)
            staging = try await serve(
                device.connection,
                image: package.logicalImage,
                until: FM1Message.stageFinishAddress,
                idleLimit: timing.stagingIdleLimit
            ) { requests, _ in
                events(.staging(requests: requests))
            }
        }
        guard staging.finished else {
            throw staging.lost
                ? FM1UpdateError.disconnected(phase: .staging, requests: staging.requests)
                : FM1UpdateError.stalled(phase: .staging, requests: staging.requests)
        }

        events(.waitingForLoader)
        try await Task.sleep(for: timing.loaderBoot)
        let loaderModel = FM1Identity.loaderPrefix + package.identity.model
        guard let loader = try await waitFor(timing.loaderSearch, where: { $0.model == loaderModel }) else {
            throw FM1UpdateError.loaderNotFound
        }
        return try await write(package, with: loader, events: events)
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
        let loaderModel = FM1Identity.loaderPrefix + package.identity.model
        guard let loader = await find(where: { $0.model == loaderModel }) else {
            throw FM1UpdateError.loaderNotFound
        }
        return try await write(package, with: loader, events: events)
    }

    /// Answers the loader's reads, then waits for the device to return running the package.
    private func write(
        _ package: FwscPackage,
        with loader: FoundDevice,
        events: @escaping @Sendable (UpdateEvent) -> Void
    ) async throws -> FM1Identity {
        let writing: ServeOutcome
        do {
            defer { loader.connection.close() }
            events(.loaderFound(loader.identity))
            try loader.connection.send(FM1Message.upgradeCommand)
            try await Task.sleep(for: timing.afterUpgradeCommand)
            let imageLength = Double(package.logicalImage.count)
            writing = try await serve(
                loader.connection,
                image: package.logicalImage,
                until: FM1Message.writeFinishAddress,
                idleLimit: timing.writeIdleLimit
            ) { requests, highestEnd in
                events(.writing(fraction: min(Double(highestEnd) / imageLength, 1), requests: requests))
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
        returned.connection.close()
        guard returned.identity == package.identity else {
            throw FM1UpdateError.identityMismatch(expected: package.product, reported: returned.identity.text)
        }
        events(.finished(returned.identity))
        return returned.identity
    }

    /// How a run of answering read requests ended.
    struct ServeOutcome {
        /// Image reads answered (finish requests aren't counted).
        var requests = 0
        /// True when the device asked for the expected finish address.
        var finished = false
        /// True when the device disconnected.
        var lost = false
    }

    /// Answers read requests until the device asks for `finishAddress`, goes quiet, or disappears.
    ///
    /// - Parameters:
    ///   - connection: The open connection to the device.
    ///   - image: The package's logical image, which the requests address.
    ///   - finishAddress: The address that ends this phase.
    ///   - idleLimit: How long the device may stay silent before the phase counts as stalled.
    ///   - progress: Called after each answered read with the number of reads so far and the
    ///     furthest image offset sent.
    /// - Returns: How the phase ended: finished, stalled or disconnected, with the reads answered.
    /// - Throws: ``FM1UpdateError/badRequest(address:length:)`` for a request outside the image,
    ///   or `CancellationError`.
    func serve(
        _ connection: any MIDIConnection,
        image: [UInt8],
        until finishAddress: UInt32,
        idleLimit: Duration,
        progress: (Int, Int) -> Void
    ) async throws -> ServeOutcome {
        var outcome = ServeOutcome()
        var highestEnd = 0
        var lastActivity = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            guard let message = await connection.receive(timeout: .seconds(1)) else {
                if connection.isLost {
                    outcome.lost = true
                    return outcome
                }
                if ContinuousClock.now - lastActivity > idleLimit {
                    return outcome
                }
                continue
            }
            guard let request = FM1ReadRequest(sysex: message) else { continue }
            lastActivity = ContinuousClock.now

            if request.isFinish {
                // The device moves on once it has asked; a lost reply shows up as a failed reconnect.
                try? connection.send(request.finishResponse())
                if request.address == finishAddress {
                    outcome.finished = true
                    return outcome
                }
                continue
            }
            let start = Int(request.address)
            guard request.length <= FM1Message.maximumReadLength, start + request.length <= image.count else {
                throw FM1UpdateError.badRequest(address: request.address, length: request.length)
            }
            try await Task.sleep(for: timing.responseDelay)
            guard (try? connection.send(request.response(with: image[start..<(start + request.length)]))) != nil else {
                outcome.lost = true
                return outcome
            }
            outcome.requests += 1
            highestEnd = max(highestEnd, start + request.length)
            progress(outcome.requests, highestEnd)
        }
    }
}
