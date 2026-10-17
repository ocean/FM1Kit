/// Checking an install before it starts, and M-VAVE's open firmware: asking about its update
/// support, and arming it for an update.
extension FM1Updater {
    /// Checks what installing a package on the connected FM-1 would do, without changing it.
    ///
    /// Use it to warn before an install that switches firmware. Only the handshake, and for open
    /// firmware the capability query, are sent.
    ///
    /// - Parameters:
    ///   - package: The firmware to install.
    ///   - buildID: The package's build ID, if known; see ``InstallOptions/buildID``.
    /// - Returns: The device and what the install would do.
    /// - Throws: ``FM1UpdateError`` when no FM-1 (or more than one) answers, or the package is
    ///   for other hardware.
    public func check(_ package: FwscPackage, buildID: FM1BuildID? = nil) async throws(FM1UpdateError)
        -> InstallCheck
    {
        guard let device = try await findOnly(where: { !$0.isLoader }) else {
            throw .deviceNotFound
        }
        defer { device.connection.close() }
        return try await check(package, on: device, buildID: buildID ?? Self.knownBuildID(of: package))
    }

    /// Checks a package against a found device: its model, and what the install would do.
    func check(_ package: FwscPackage, on device: FoundDevice, buildID: FM1BuildID?)
        async throws(FM1UpdateError) -> InstallCheck
    {
        let capability = try await capability(of: device)
        guard
            device.identity.hardwareModel == package.identity.model
                || capability?.family == FM1Capability.fm1Family
        else {
            throw .modelMismatch(device: device.identity.text, package: package.product)
        }
        return InstallCheck(device: device.identity, capability: capability, package: package, buildID: buildID)
    }

    /// Sends a command and waits for the reply to it.
    ///
    /// - Returns: The reply's payload, or `nil` if none came within ``UpdaterTiming/commandReplyWait``.
    func query(_ connection: any MIDIConnection, command: UInt8, payload: [UInt8] = []) async -> [UInt8]? {
        connection.drain()
        guard (try? connection.send(FM1Message.command(command, payload: payload))) != nil else { return nil }
        let deadline = ContinuousClock.now + timing.commandReplyWait
        while ContinuousClock.now < deadline {
            guard let reply = await connection.receive(timeout: deadline - ContinuousClock.now) else { break }
            if let (replyCommand, replyPayload) = FM1Message.parseCommand(reply), replyCommand == command {
                return replyPayload
            }
        }
        return nil
    }

    /// Asks open firmware about its update support; other firmwares aren't asked.
    ///
    /// - Returns: The capability, or `nil` when the device isn't running open firmware.
    /// - Throws: ``FM1UpdateError/capabilityUnavailable`` when open firmware doesn't answer properly.
    func capability(of device: FoundDevice) async throws(FM1UpdateError) -> FM1Capability? {
        guard device.identity.isOpenFirmware else { return nil }
        guard
            let payload = await query(device.connection, command: FM1Message.capabilityCommand),
            let capability = FM1Capability(payload: payload)
        else {
            throw .capabilityUnavailable
        }
        return capability
    }

    /// The build ID FM1Kit knows for a package: an official release's.
    static func knownBuildID(of package: FwscPackage) -> FM1BuildID? {
        OfficialFirmware.matching(package)?.buildID
    }

    /// Arms open firmware for the package, as it requires before the upgrade command.
    ///
    /// Without a build ID, it's armed with the package file's SHA-256, as M-VAVE's updater does for
    /// firmwares without their own.
    func arm(
        _ connection: any MIDIConnection,
        capability: FM1Capability,
        package: FwscPackage,
        buildID: FM1BuildID?
    ) async throws(FM1UpdateError) {
        guard capability.isReady else { throw .deviceBusy }
        let payload = FM1Capability.armPayload(
            family: capability.family,
            imageLength: package.logicalImage.count,
            buildID: buildID ?? FM1BuildID(knownHex: package.sha256)
        )
        guard let reply = await query(connection, command: FM1Message.armCommand, payload: payload) else {
            throw .armRefused(code: nil)
        }
        guard reply == FM1Capability.armAccepted else {
            throw .armRefused(code: reply.first.map(Int.init) ?? -1)
        }
    }
}
