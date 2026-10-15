import Foundation

/// Timings for an update session. The standard values follow the FM-1-RE protocol notes and
/// have not yet been tuned against a wide range of hardware.
public struct UpdaterTiming: Sendable {
    /// Pause after an upgrade command before the device starts asking for data.
    public var afterUpgradeCommand: Duration = .seconds(2)
    /// Give up staging when the device has been silent this long.
    public var stagingIdleLimit: Duration = .seconds(8)
    /// Pause after staging while the device reboots into the loader.
    public var loaderBoot: Duration = .seconds(3)
    /// How long to look for the loader after staging.
    public var loaderSearch: Duration = .seconds(30)
    /// Give up writing when the loader has been silent this long.
    public var writeIdleLimit: Duration = .seconds(60)
    /// Pause after writing while the device reboots into the new firmware.
    public var firmwareBoot: Duration = .seconds(3)
    /// How long to look for the device after writing.
    public var returnSearch: Duration = .seconds(40)
    /// Pause before each response, giving the device time between packets.
    public var responseDelay: Duration = .milliseconds(10)
    /// Time between port scans while waiting for a device.
    public var scanInterval: Duration = .seconds(1)
    /// How long to wait for a handshake reply.
    public var handshakeWait: Duration = .seconds(1)
    /// Handshake attempts per port.
    public var handshakeAttempts = 2

    /// The standard timings.
    public init() {}

    /// The timings from the protocol notes.
    public static let standard = UpdaterTiming()
}

/// Progress reported during an update.
public enum UpdateEvent: Sendable, Equatable {
    case connected(FM1Identity)
    /// Staging (nothing written yet): the number of reads answered.
    case staging(requests: Int)
    case waitingForLoader
    case loaderFound(FM1Identity)
    /// Writing: how far through the image the device has read (0...1).
    case writing(fraction: Double, requests: Int)
    case rebooting
    case finished(FM1Identity)
    case log(String)
}

/// Why an update stopped. Each has a description that says what to do next.
public enum FM1UpdateError: Error, Equatable, LocalizedError {
    case deviceNotFound
    case modelMismatch(device: String, package: String)
    case stalled(phase: Phase, requests: Int)
    case disconnected(phase: Phase, requests: Int)
    case loaderNotFound
    case deviceDidNotReturn
    case identityMismatch(expected: String, reported: String)
    case badRequest(address: UInt32, length: Int)

    /// Which half of an update failed: staging writes nothing, writing leaves the loader waiting.
    public enum Phase: String, Sendable {
        case staging
        case writing
    }

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "No FM-1 found. Check the cable, and close any other app using it."
        case .modelMismatch(let device, let package):
            return "The device is \(device) but the package is for \(package)."
        case .stalled(.staging, let requests):
            return "The FM-1 stopped after \(requests) requests while checking the package. Nothing was written."
        case .disconnected(.staging, let requests):
            return "The FM-1 disconnected after \(requests) requests while checking the package. Nothing was written."
        case .stalled(.writing, let requests):
            return "The loader stopped after \(requests) requests. Keep it connected and choose Resume."
        case .disconnected(.writing, let requests):
            return "The loader disconnected after \(requests) requests. Reconnect and choose Resume; it stays in update mode until finished."
        case .loaderNotFound:
            return "The update loader did not appear. Replug the cable and try again; the device stays in update mode."
        case .deviceDidNotReturn:
            return "The FM-1 did not come back after writing. Switch it off and on again."
        case .identityMismatch(let expected, let reported):
            return "Written, but the FM-1 reports \(reported) instead of \(expected)."
        case .badRequest(let address, let length):
            return "The device asked for an impossible range (0x\(String(address, radix: 16)), \(length) bytes). Stopped without answering."
        }
    }
}

/// A device found on a port, with its connection still open.
public struct FoundDevice: Sendable {
    /// The open connection; close it when done.
    public let connection: any MIDIConnection
    /// What the device said it is.
    public let identity: FM1Identity
}

/// Runs the FM-1 USB-MIDI update protocol over any `MIDITransport`.
///
/// Install flow: handshake, upgrade command, answer staging reads until the device asks for
/// `0xE0000000`, wait for the `ota-` loader, upgrade command again, answer write reads until
/// `0xF0000000`, then wait for the device and check it reports the package's identity.
public actor FM1Updater {
    /// Only ports whose names contain one of these are probed, so SysEx is never sent to other gear.
    public static let probeablePortNameFragments = ["fm-1", "fm1", "felucca", "ota", "composite", "usb-midi", "simulated"]

    /// True when the port's name contains one of `probeablePortNameFragments`.
    public static func isProbeable(_ port: MIDIPortDescriptor) -> Bool {
        let name = port.name.lowercased()
        return probeablePortNameFragments.contains { name.contains($0) }
    }

    /// Where devices are found.
    public let transport: any MIDITransport
    /// How long to wait at each step.
    public let timing: UpdaterTiming

    /// An updater that finds devices through `transport`.
    public init(transport: any MIDITransport, timing: UpdaterTiming = .standard) {
        self.transport = transport
        self.timing = timing
    }

    // MARK: - Discovery.

    /// The first probeable port that answers the handshake (and passes `filter`), left open.
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

    /// Asks what the connected FM-1 is running, then closes the connection.
    public func identify() async -> FM1Identity? {
        guard let device = await find() else { return nil }
        device.connection.close()
        return device.identity
    }

    func waitFor(_ limit: Duration, where filter: @escaping @Sendable (FM1Identity) -> Bool) async -> FoundDevice? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let device = await find(where: filter) {
                return device
            }
            try? await Task.sleep(for: timing.scanInterval)
        }
        return nil
    }

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

    /// Installs a package on a device running firmware (official or custom).
    /// If the device is already in its loader (an interrupted update, or USB rescue), use `resume`.
    @discardableResult
    public func install(_ package: FwscPackage, events: @escaping @Sendable (UpdateEvent) -> Void = { _ in }) async throws -> FM1Identity {
        guard let device = await find(where: { !$0.isLoader }) else {
            throw FM1UpdateError.deviceNotFound
        }
        guard device.identity.hardwareModel == package.identity.model else {
            device.connection.close()
            throw FM1UpdateError.modelMismatch(device: device.identity.text, package: package.product)
        }
        events(.connected(device.identity))

        try device.connection.send(FM1Message.upgradeCommand)
        try? await Task.sleep(for: timing.afterUpgradeCommand)
        let staging = try await serve(
            device.connection,
            image: package.logicalImage,
            until: FM1Message.stageFinishAddress,
            idleLimit: timing.stagingIdleLimit
        ) { requests, _ in
            events(.staging(requests: requests))
        }
        device.connection.close()
        guard staging.finished else {
            throw staging.lost
                ? FM1UpdateError.disconnected(phase: .staging, requests: staging.requests)
                : FM1UpdateError.stalled(phase: .staging, requests: staging.requests)
        }

        events(.waitingForLoader)
        try? await Task.sleep(for: timing.loaderBoot)
        let loaderModel = FM1Identity.loaderPrefix + package.identity.model
        guard let loader = await waitFor(timing.loaderSearch, where: { $0.model == loaderModel }) else {
            throw FM1UpdateError.loaderNotFound
        }
        return try await write(package, with: loader, events: events)
    }

    /// Finishes an update with the device already in its loader.
    @discardableResult
    public func resume(_ package: FwscPackage, events: @escaping @Sendable (UpdateEvent) -> Void = { _ in }) async throws -> FM1Identity {
        let loaderModel = FM1Identity.loaderPrefix + package.identity.model
        guard let loader = await find(where: { $0.model == loaderModel }) else {
            throw FM1UpdateError.loaderNotFound
        }
        return try await write(package, with: loader, events: events)
    }

    private func write(_ package: FwscPackage, with loader: FoundDevice, events: @escaping @Sendable (UpdateEvent) -> Void) async throws -> FM1Identity {
        events(.loaderFound(loader.identity))
        try loader.connection.send(FM1Message.upgradeCommand)
        try? await Task.sleep(for: timing.afterUpgradeCommand)
        let imageLength = Double(package.logicalImage.count)
        let writing = try await serve(
            loader.connection,
            image: package.logicalImage,
            until: FM1Message.writeFinishAddress,
            idleLimit: timing.writeIdleLimit
        ) { requests, highestEnd in
            events(.writing(fraction: min(Double(highestEnd) / imageLength, 1), requests: requests))
        }
        loader.connection.close()
        guard writing.finished else {
            throw writing.lost
                ? FM1UpdateError.disconnected(phase: .writing, requests: writing.requests)
                : FM1UpdateError.stalled(phase: .writing, requests: writing.requests)
        }

        events(.rebooting)
        try? await Task.sleep(for: timing.firmwareBoot)
        guard let returned = await waitFor(timing.returnSearch, where: { !$0.isLoader }) else {
            throw FM1UpdateError.deviceDidNotReturn
        }
        returned.connection.close()
        guard returned.identity == package.identity else {
            throw FM1UpdateError.identityMismatch(expected: package.product, reported: returned.identity.text)
        }
        events(.finished(returned.identity))
        return returned.identity
    }

    struct ServeOutcome {
        var requests = 0
        var finished = false
        var lost = false
    }

    /// Answers read requests until the device asks for `finishAddress`, goes quiet, or disappears.
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
            try? await Task.sleep(for: timing.responseDelay)
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
