/// Installing m-bootloader over USB-MIDI, from its installer package.
extension FM1Updater {
    /// Installs m-bootloader on the connected FM-1, keeping its firmware.
    ///
    /// V15 stages the installer like an update and restarts. The bootloader runs it: it rewrites
    /// only the 16 KB boot area, checks it, shows `INSTALLED` (or what went wrong) on the FM-1's
    /// screen and restarts into the same firmware. This answers the staging reads, waits for the
    /// FM-1 to restart, then for it to come back running the same firmware.
    ///
    /// FM1Kit can't read the boot area over USB-MIDI, so it can't confirm the result: the FM-1
    /// comes back either way. Ask the person what the screen showed, or to hold PLAY while
    /// switching on and look for m-bootloader's menu. Installing V15 later puts M-VAVE's
    /// bootloader back.
    ///
    /// Only V15 is allowed for now: it's the only firmware m-bootloader's installer has been
    /// tested from. A power cut while the installer writes the boot area can leave the FM-1
    /// unable to start; recovering it then needs a USB_KEY dongle.
    ///
    /// - Parameters:
    ///   - installer: The installer, from m-bootloader's `fm1-uboot.fwsc`.
    ///   - fromAnyFirmware: Sends the installer whatever firmware is running, for hardware tests
    ///     of how other firmwares treat it. Most refuse it while staging.
    ///   - events: Progress: ``UpdateEvent/connected(_:)``, ``UpdateEvent/staging(requests:)``,
    ///     ``UpdateEvent/rebooting`` while the installer runs, then ``UpdateEvent/finished(_:)``;
    ///     it may be called from any task.
    /// - Returns: The identity the FM-1 reports once it's back, the same as before.
    /// - Throws: ``FM1UpdateError`` when the FM-1 isn't running V15, more than one answers, or
    ///   it stops or doesn't come back; a ``MIDITransportError`` when sending fails; or
    ///   `CancellationError`.
    @discardableResult
    public func installBootloader(
        _ installer: BootloaderInstaller,
        fromAnyFirmware: Bool = false,
        events: @escaping @Sendable (UpdateEvent) -> Void = { _ in }
    ) async throws -> FM1Identity {
        guard let device = try await findOnly(where: { !$0.isLoader }) else {
            throw FM1UpdateError.deviceNotFound
        }
        let running = device.identity
        let staging: ServeOutcome
        do {
            defer { device.connection.close() }
            guard fromAnyFirmware || running == .officialV15 else {
                throw FM1UpdateError.bootloaderInstallNeedsV15(device: running.text)
            }
            events(.connected(running))
            try device.connection.send(FM1Message.upgradeCommand)
            try await pause(timing.afterUpgradeCommand)
            staging = try await serve(
                device.connection,
                image: installer.package.logicalImage,
                phase: .staging,
                idleLimit: timing.stagingIdleLimit
            ) { _, requests in
                events(.staging(requests: requests))
            }
            guard staging.finished else {
                if Self.refusedPackage(staging, of: installer.package) {
                    throw FM1UpdateError.packageRefused(requests: staging.requests)
                }
                throw staging.lost
                    ? FM1UpdateError.disconnected(phase: .staging, requests: staging.requests)
                    : FM1UpdateError.stalled(phase: .staging, requests: staging.requests)
            }
            // Without a restart, the installer never ran.
            guard try await waitUntilLost(device.connection, limit: timing.loaderSearch) else {
                throw FM1UpdateError.installerDidNotStart
            }
        }

        events(.rebooting)
        try await Task.sleep(for: timing.firmwareBoot)
        guard let returned = try await waitFor(timing.returnSearch, where: { _ in true }) else {
            throw FM1UpdateError.deviceDidNotReturn
        }
        returned.connection.close()
        guard returned.identity == running else {
            throw FM1UpdateError.identityMismatch(expected: running.text, reported: returned.identity.text)
        }
        events(.finished(returned.identity))
        return returned.identity
    }

    /// Waits until a connection's device has gone, as it does when the FM-1 restarts.
    ///
    /// - Returns: True once it's gone, false if it's still there after `limit`.
    func waitUntilLost(_ connection: any MIDIConnection, limit: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while !connection.isLost {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
