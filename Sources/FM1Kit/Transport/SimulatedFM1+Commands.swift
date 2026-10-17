import os

/// The simulated FM-1's answers to open firmware's capability and arming commands, and to V15's
/// voice erases and writes.
extension SimulatedFM1 {
    /// Answers a capability query or arming request, as open firmware does; others ignore them.
    func handleOpenFirmwareCommand(_ command: UInt8, payload: [UInt8], from connection: SimulatedConnection) {
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

    /// Erases or writes part of a voice bank, as V15 does; other firmwares ignore these.
    func handleVoiceCommand(_ command: UInt8, payload: [UInt8], from connection: SimulatedConnection) {
        guard currentIdentity == FM1Identity.officialV15, payload.count >= 5,
            payload[0] == FM1Message.voiceArea
        else {
            return
        }
        let address = Int(FM1Message.readLittleEndian(payload, at: 1, byteCount: 4))
        let reply: UInt8? = state.withLock { state in
            if let limit = options.stopsAnsweringVoicesAfter, state.voiceSteps >= limit { return nil }
            state.voiceSteps += 1
            guard options.voiceReply == 0 else { return options.voiceReply }
            if command == FM1Message.voiceEraseCommand {
                let bank = address..<min(address + FwscPackage.voiceBankLength, state.voices.count)
                state.voices.replaceSubrange(bank, with: repeatElement(0xFF, count: bank.count))
                return 0
            }
            let length = payload.count >= 8 ? Int(FM1Message.readLittleEndian(payload, at: 5, byteCount: 3)) : -1
            guard length == payload.count - 8, address + length <= state.voices.count else { return 1 }
            state.voices.replaceSubrange(address..<(address + length), with: payload[8...])
            return 0
        }
        guard let reply else {
            log("Stopped answering the voice restore.")
            return
        }
        connection.toHost.deliver(FM1Message.command(FM1Message.acknowledgementCommand, payload: [reply]))
    }
}
