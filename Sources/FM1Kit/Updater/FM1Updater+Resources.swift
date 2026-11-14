/// Writing a firmware's resource region over USB-MIDI, as fm1-base's installer does once the
/// firmware is running.
extension FM1Updater {
    /// The command that asks a firmware to take resources: the payload's length and CRC-32.
    static let resourceCommand: UInt8 = 0x44
    /// The read a firmware makes to report the resources written.
    static let resourcesWrittenAddress: UInt32 = 0xC000_0000
    /// The read a firmware makes just before asking a question on its screen.
    static let resourcesAskAddress: UInt32 = 0xC100_0000
    /// The read a firmware makes to report a failure, with its code in the low 16 bits.
    static let resourcesFailedAddress: UInt32 = 0xCF00_0000

    /// Writes a firmware's resources into the only FM-1, over USB-MIDI.
    ///
    /// The FM-1 must be running the firmware the resources belong to, built with fm1-base: it
    /// takes only its own build's resources (by their length and CRC-32), erases its resource
    /// region, reads the payload, checks it as written and writes the header last. A firmware
    /// that holds them already answers at once. If the write stops part-way, the firmware does
    /// without its resources until they're written again; nothing else changes.
    ///
    /// Use it after installing a firmware whose resources are published beside its package
    /// (`NAME-res.bin`), such as LOOM-8 from 0.12. Packages that carry their resources (see
    /// ``FwscPackage/resources``) don't need it: the update loader writes them.
    ///
    /// - Parameters:
    ///   - resources: The resources, from a `NAME-res.bin` file.
    ///   - progress: Called with the share of the payload sent so far (0 to 1); it may be called
    ///     from any task.
    /// - Throws: ``FM1UpdateError`` when no single FM-1 running firmware is found, it doesn't
    ///   ask for the resources, refuses them or stops asking; or `CancellationError`.
    public func writeResources(
        _ resources: ResourceRegion,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let device = try await findOnly(where: { !$0.isLoader }) else { throw FM1UpdateError.deviceNotFound }
        defer { device.connection.close() }
        let connection = device.connection
        let payload = Array(resources.payload)
        connection.drain()
        let request =
            FM1Message.littleEndian(UInt32(payload.count), byteCount: 4)
            + FM1Message.littleEndian(resources.payloadCRC, byteCount: 4)
        try connection.send(FM1Message.command(Self.resourceCommand, payload: request))

        progress(0)
        var sent = 0
        var asked = false
        let sectors = (ResourceRegion.headerLength + payload.count + 0xFFF) / 0x1000
        var waitLimit = timing.resourceStartWait + timing.resourceSectorEraseWait * sectors
        var lastActivity = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            if ContinuousClock.now - lastActivity > waitLimit {
                throw asked
                    ? FM1UpdateError.resourcesStalled(bytesSent: sent)
                    : FM1UpdateError.resourcesNotTaken(device: device.identity.text)
            }
            guard let message = await connection.receive(timeout: .seconds(1)) else {
                if connection.isLost { throw FM1UpdateError.resourcesStalled(bytesSent: sent) }
                continue
            }
            guard let read = FM1ReadRequest(sysex: message) else { continue }
            lastActivity = ContinuousClock.now
            waitLimit = timing.resourceIdleLimit
            asked = true

            if Self.isResourceReport(read.address) {
                // The firmware has reported already; if this answer is lost, its read times out.
                try? connection.send(read.finishResponse())
                if read.address == Self.resourcesAskAddress {
                    waitLimit = timing.resourceAskWait
                    continue
                }
                guard read.address == Self.resourcesWrittenAddress else {
                    throw FM1UpdateError.resourcesRefused(code: Int(read.address & 0xFFFF))
                }
                progress(1)
                return
            }
            let start = Int(read.address)
            guard read.length <= FM1Message.maximumReadLength, start < payload.count else {
                throw FM1UpdateError.resourcesBadRequest(address: read.address, length: read.length)
            }
            // The last read can run past the payload; the firmware takes zeros there.
            let data = payload[start..<min(start + read.length, payload.count)]
            let padded = Array(data) + [UInt8](repeating: 0, count: read.length - data.count)
            try await pause(timing.responseDelay)
            guard (try? connection.send(read.response(with: padded))) != nil else {
                throw FM1UpdateError.resourcesStalled(bytesSent: sent)
            }
            sent = max(sent, start + data.count)
            progress(Double(sent) / Double(max(payload.count, 1)))
        }
    }

    /// True for the reads a firmware makes to report on the resources, rather than to read them.
    static func isResourceReport(_ address: UInt32) -> Bool {
        [resourcesWrittenAddress, resourcesAskAddress, resourcesFailedAddress].contains(address & 0xFF00_0000)
    }
}

extension FM1UpdateError {
    /// What a firmware's refusal code means, from fm1-base's `device/res.c` and `device/backup.c`.
    static func resourcesRefusal(code: Int) -> String {
        switch code {
        case 2:
            "The FM-1 stopped the resource write: a read went unanswered. Reconnect it and write them again."
        case 7, 8:
            "The FM-1 couldn't \(code == 7 ? "erase" : "write") its flash for the resources (code \(code))."
        case 10:
            "The FM-1 is playing. Press STOP, then write the resources again."
        case 20:
            """
            These resources belong to another build than the firmware the FM-1 is running. \
            Use the NAME-res.bin from the same release as its package.
            """
        case 21:
            """
            The FM-1 is still moving its projects into their new place. Switch it off and on, then write \
            the resources again.
            """
        case 22:
            "The resources didn't check after writing (code 22). Write them again."
        default:
            "The FM-1 refused the resources (code \(code))."
        }
    }
}
