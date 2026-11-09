import Testing

@_spi(Testing) @testable import FM1Kit

/// What `monitor`, `replay` and the message logs call each message.
struct MessageDescriptionTests {
    private func describe(_ sysex: [UInt8], _ direction: FM1MessageDescription.Direction) -> String {
        FM1MessageDescription(sysex, direction: direction).text
    }

    @Test func namesTheHandshakeAndItsReply() throws {
        #expect(describe(FM1Message.handshakeQuery, .toDevice) == "handshake: asks who the device is")
        #expect(describe(FM1Message.fullIdentityQuery, .toDevice) == "full identity query: asks for the whole identity")
        let reply = FM1Identity.officialV15.handshakeReply(flashChipID: FM1FlashChip.uc25hq80)
        #expect(describe(reply, .fromDevice) == "identity FM-1_015: firmware, flash chip UC25HQ80")
        let loader = try #require(FM1Identity(text: "ota-FM-1_015")).handshakeReply()
        #expect(describe(loader, .fromDevice) == "identity ota-FM-1_015: update loader")
    }

    @Test func namesReadsFinishesAndResponses() {
        let read = FM1ReadRequest(address: 0x4000, length: 512)
        #expect(describe(read.encoded(), .fromDevice) == "read: 0x00004000, 512 bytes")
        #expect(
            describe(read.response(with: [UInt8](repeating: 0, count: 512)), .toDevice)
                == "response: 0x00004000, 512 bytes")
        let staged = FM1ReadRequest(address: FM1Message.stageFinishAddress, length: 8)
        #expect(describe(staged.encoded(), .fromDevice) == "finish: staging done; restarting into the update loader")
        #expect(describe(staged.finishResponse(), .toDevice) == "response: success")
        #expect(describe(FM1Message.upgradeCommand, .toDevice) == "upgrade: starts an update session")
    }

    @Test func namesVoiceMessages() {
        let erase = FM1Message.command(
            FM1Message.voiceEraseCommand, payload: [5] + FM1Message.littleEndian(0xF_C000, byteCount: 4))
        #expect(describe(erase, .toDevice) == "voice erase: bank at 0x000FC000")
        #expect(
            describe(FM1Message.command(FM1Message.acknowledgementCommand, payload: [0]), .fromDevice)
                == "acknowledgement: done")
    }

    @Test func readsOpenFirmwaresCapability() {
        let capability = FM1Capability(state: 0, buildID: FM1BuildID(bytes: [UInt8](repeating: 0xAB, count: 32)))
        let reply = FM1Message.command(FM1Message.capabilityCommand, payload: capability.payload())
        #expect(describe(reply, .fromDevice) == "capability: family 7, ready, build abababababababab…")
        #expect(
            describe(FM1Message.command(FM1Message.capabilityCommand), .toDevice)
                == "capability: asks about update support")
    }

    @Test func namesLibraryMessages() {
        let request = ProjectLibraryMessage.request(.read, token: 300, payload: [64, 0, 64])
        #expect(describe(request, .toDevice) == "library read: token 300, offset 64, 64 bytes")
        let reply = ProjectLibraryMessage.frame(0x40 | 9, token: 301, payload: [1])
        #expect(describe(reply, .fromDevice) == "library slot name reply: token 301, empty, 0 bytes")
    }

    @Test func saysWhenAKnownCommandIsDamaged() {
        var body = SevenBit.unpack(
            FM1Message.command(FM1Message.voiceWriteCommand, payload: [5, 0, 0, 0, 0, 1, 0, 0, 9]).dropFirst()
                .dropLast())
        body[body.count - 1] ^= 0x01
        #expect(
            describe([0xF0] + SevenBit.pack(body) + [0xF7], .toDevice)
                == "voice write: checksum or length doesn't match")
    }

    @Test func leavesOtherMessagesAsOther() {
        #expect(describe([0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7], .toDevice) == "device inquiry: device 127")
        #expect(describe([0xF0, 0x43, 0x10, 0xF7], .fromDevice) == "other: 4 bytes")
        #expect(describe([0xF0, 0x43], .fromDevice) == "incomplete: 2 bytes without F0 … F7")
    }
}
