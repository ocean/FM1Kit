/// Restoring V15's factory voices, as M-VAVE's updater does after installing V15.
extension FM1Updater {
    /// The identity a voice restore needs the device to report.
    static let v15Identity = FM1Identity.officialV15

    /// Rewrites the FM-1's four voice banks with V15's 128 factory voices.
    ///
    /// Installing V15 over other firmware can leave a bank holding the earlier firmware's voices,
    /// some of them silent. This erases each 4 KB bank and writes it again from the official V15
    /// package, 512 bytes at a time, waiting for V15 to acknowledge each step, as M-VAVE's
    /// updater does. It runs only while the FM-1 reports `FM-1_015`, which it checks before and
    /// after.
    ///
    /// Every voice in the four banks is replaced, including any the person made, and V15 can't
    /// read the banks back, so warn first. If the restore is interrupted, some voices may be
    /// wrong or silent until it's run again.
    ///
    /// - Parameters:
    ///   - package: M-VAVE's official V15 package; see ``FwscPackage/hasFactoryVoices``.
    ///   - progress: Called with the share of the voices written so far (0 to 1); it may be
    ///     called from any task.
    /// - Throws: ``FM1UpdateError`` when the package or device isn't V15, more than one FM-1
    ///   answers, or V15 refuses or stops answering; or `CancellationError`.
    public func restoreFactoryVoices(
        from package: FwscPackage,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let voices = package.factoryVoices() else { throw FM1UpdateError.factoryVoicesUnavailable }
        try await restoreVoices(voices, progress: progress)
    }

    /// Writes 16 KB of voices to the only FM-1, which must be running V15.
    func restoreVoices(_ voices: [UInt8], progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let device = try await findOnly(where: { _ in true }) else { throw FM1UpdateError.deviceNotFound }
        defer { device.connection.close() }
        guard device.identity == Self.v15Identity else {
            throw FM1UpdateError.voiceRestoreNeedsV15(device: device.identity.text)
        }

        progress(0)
        let bankLength = FwscPackage.voiceBankLength
        let writeLength = FM1Message.voiceWriteLength
        for bank in stride(from: 0, to: voices.count, by: bankLength) {
            try await acknowledge(
                device.connection,
                command: FM1Message.voiceEraseCommand,
                payload: Self.voiceAddress(bank),
                bytesWritten: bank
            )
            for offset in stride(from: bank, to: bank + bankLength, by: writeLength) {
                let payload =
                    Self.voiceAddress(offset) + FM1Message.littleEndian(UInt32(writeLength), byteCount: 3)
                    + voices[offset..<(offset + writeLength)]
                try await acknowledge(
                    device.connection,
                    command: FM1Message.voiceWriteCommand,
                    payload: payload,
                    bytesWritten: offset
                )
                progress(Double(offset + writeLength) / Double(voices.count))
            }
        }

        guard await handshake(device.connection) == Self.v15Identity else {
            throw FM1UpdateError.voiceRestoreNeedsV15(device: "an unexpected identity after the restore")
        }
    }

    /// The voice area and a 32-bit address in it.
    static func voiceAddress(_ address: Int) -> [UInt8] {
        [FM1Message.voiceArea] + FM1Message.littleEndian(UInt32(address), byteCount: 4)
    }

    /// Sends one step of a voice restore and waits for V15 to acknowledge it.
    private func acknowledge(
        _ connection: any MIDIConnection,
        command: UInt8,
        payload: [UInt8],
        bytesWritten: Int
    ) async throws {
        try Task.checkCancellation()
        connection.drain()
        guard (try? connection.send(FM1Message.command(command, payload: payload))) != nil else {
            throw FM1UpdateError.voiceRestoreStalled(bytesWritten: bytesWritten)
        }
        let deadline = ContinuousClock.now + timing.voiceReplyWait
        while ContinuousClock.now < deadline, !connection.isLost {
            guard let reply = await connection.receive(timeout: deadline - ContinuousClock.now) else { continue }
            guard let (replyCommand, replyPayload) = FM1Message.parseCommand(reply),
                replyCommand == FM1Message.acknowledgementCommand
            else {
                continue
            }
            guard replyPayload == [0] else {
                throw FM1UpdateError.voiceRestoreRefused(
                    code: replyPayload.count == 1 ? Int(replyPayload[0]) : -1, bytesWritten: bytesWritten)
            }
            return
        }
        throw FM1UpdateError.voiceRestoreStalled(bytesWritten: bytesWritten)
    }
}
