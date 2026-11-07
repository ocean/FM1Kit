import Testing

@_spi(Testing) @testable import FM1Kit

struct SevenBitTests {
    @Test func packsLeastSignificantBitFirst() {
        #expect(SevenBit.pack([0xFF]) == [0x7F, 0x01])
        #expect(SevenBit.pack([0x00, 0x59, 0x30]) == [0x00, 0x32, 0x41, 0x01])
    }

    @Test func roundTripsEveryLength() {
        for length in 0...40 {
            let bytes = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
            #expect(Array(SevenBit.unpack(SevenBit.pack(bytes)).prefix(length)) == bytes)
            #expect(SevenBit.pack(bytes).allSatisfy { $0 < 0x80 })
        }
    }
}

struct MessageTests {
    @Test func handshakeQueryDecodesToTheDocumentedHeader() {
        // The query unpacks to 00 59 11: the identity command the reply also carries.
        let body = SevenBit.unpack(FM1Message.handshakeQuery.dropFirst().dropLast())
        #expect(Array(body.prefix(3)) == [0x00, 0x59, FM1Message.identityCommand])
    }

    @Test func readRequestRoundTrips() throws {
        let request = FM1ReadRequest(flashType: 1, address: 0x0001_2340, length: 481)
        let parsed = try #require(FM1ReadRequest(sysex: request.encoded()))
        #expect(parsed == request)
    }

    @Test func readRequestWithBadChecksumIsIgnored() {
        var body = SevenBit.unpack(FM1ReadRequest(address: 0x100, length: 16).encoded().dropFirst().dropLast())
        body[14] ^= 0x01
        #expect(FM1ReadRequest(sysex: [0xF0] + SevenBit.pack(body) + [0xF7]) == nil)
    }

    @Test func responseDeclaresTheFullLength() throws {
        // The device rejects a response whose declared length is wrong (the 481-byte case in the notes).
        let request = FM1ReadRequest(address: 0x40, length: 481)
        let data = (0..<481).map { UInt8(truncatingIfNeeded: $0) }
        let parsed = try #require(FM1ReadRequest.parseResponse(request.response(with: data)))
        #expect(parsed.request.address == 0x40)
        #expect(parsed.data == data)
        let body = SevenBit.unpack(request.response(with: data).dropFirst().dropLast())
        #expect(Int(FM1Message.readLittleEndian(body, at: 3, byteCount: 3)) == 481 + 8)
        #expect(Int(FM1Message.readLittleEndian(body, at: 3, byteCount: 3)) + 7 == 481 + 15)
    }

    @Test func identityRoundTripsAndRecognisesTheLoader() throws {
        let identity = try #require(FM1Identity(text: "ota-FM-1_009"))
        #expect(identity.isLoader)
        #expect(identity.hardwareModel == "FM-1")
        #expect(identity.version == 9)
        #expect(FM1Identity(handshakeReply: identity.handshakeReply()) == identity)
        #expect(FM1Identity(text: "FM-1_91035")?.version == 91035)
        #expect(FM1Identity(text: "nonsense") == nil)
    }
}

struct UMPTests {
    @Test func shortMessageIsOneCompletePacket() {
        let packets = UMPSysex7.packets(for: FM1Message.upgradeCommand)
        #expect(packets.count == 1)
        var assembler = UMPSysex7.Assembler()
        #expect(assembler.consume(packets[0].0, packets[0].1) == FM1Message.upgradeCommand)
    }

    @Test func longMessageSplitsAndReassembles() {
        let message = FM1ReadRequest(address: 0, length: 512).response(with: [UInt8](repeating: 0xA5, count: 512))
        let packets = UMPSysex7.packets(for: message)
        #expect(packets.count > 2)
        var assembler = UMPSysex7.Assembler()
        var result: [UInt8]?
        for (word0, word1) in packets {
            #expect(UMPSysex7.wordCount(forFirstWord: word0) == 2)
            result = assembler.consume(word0, word1) ?? result
        }
        #expect(result == message)
    }
}

struct PackageTests {
    @Test func decodesProductAndStripsMarkers() throws {
        let image = FwscPackage.sampleImage(parts: [.flash(), .loader()], seed: 7)
        let file = FwscPackage.sampleFile(logicalImage: image, product: "FM-1_916")
        #expect(file.count == image.count + 20)
        let package = try FwscPackage(bytes: file)
        #expect(package.product == "FM-1_916")
        #expect(package.logicalImage == image)
    }

    @Test func rejectsOtherFiles() {
        #expect(throws: FwscPackage.Failure.tooShort) { try FwscPackage(bytes: [1, 2, 3]) }
        #expect(throws: FwscPackage.Failure.self) { try FwscPackage(bytes: [UInt8](repeating: 0x41, count: 4000)) }
    }
}

struct RecordedDeviceTests {
    /// A real FM-1's handshake reply, as recorded in FM-1-RE's `docs/io/11-ota-protocol.md`.
    static let recordedReply: [UInt8] =
        [0xF0, 0x00, 0x32, 0x45, 0x58, 0x01, 0x00, 0x00, 0x23, 0x4D, 0x5A, 0x44, 0x79, 0x05, 0x06, 0x4C, 0x1C]
        + [UInt8](repeating: 0, count: 21) + [0x40, 0x05, 0xF7]

    @Test func readsARealDevicesHandshakeReply() throws {
        let identity = try #require(FM1Identity(handshakeReply: Self.recordedReply))
        #expect(identity.text == "FM-1_009")
        #expect(identity.handshakeReply() == Self.recordedReply)
    }

    @Test func rejectsAReplyWithABadChecksum() {
        var corrupted = Self.recordedReply
        corrupted[corrupted.count - 2] ^= 0x01
        #expect(FM1Identity(handshakeReply: corrupted) == nil)
    }

    @Test func sendsTheDocumentedCommands() {
        #expect(FM1Message.handshakeQuery == [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0xF7])
        #expect(FM1Message.upgradeCommand == [0xF0, 0x22, 0x24, 0x35, 0x7F, 0xF7])
    }
}

struct FlashChipTests {
    @Test func readsTheChipAFirmwareReportsAfterItsIdentity() throws {
        let identity = try #require(FM1Identity(text: "FM-1_378000"))
        let reply = identity.handshakeReply(flashChipID: FM1FlashChip.uc25hq80)
        #expect(FM1Identity(handshakeReply: reply) == identity)
        #expect(FM1Identity.flashChipID(inHandshakeReply: reply) == 0xB3_6014)
        #expect(FM1FlashChip.name(0xB3_6014) == "UC25HQ80")
        // Bytes 24 to 26 of the 27 after the header, as felucca-bsp's ota.c sends them.
        let body = try #require(FM1Message.unframe(reply))
        #expect(Array(body[30..<33]) == [0xB3, 0x60, 0x14])
    }

    @Test func findsNoChipInAReplyWithoutOne() throws {
        #expect(FM1Identity.flashChipID(inHandshakeReply: RecordedDeviceTests.recordedReply) == nil)
        #expect(FM1Identity.flashChipID(inHandshakeReply: FM1Message.handshakeQuery) == nil)
    }

    @Test func aFoundDeviceCarriesTheChip() async throws {
        var options = UpdaterTests.fastOptions
        options.flashChipID = FM1FlashChip.uc25hq80
        let updater = FM1Updater(transport: SimulatedFM1(options: options), timing: UpdaterTests.fastTiming)
        let device = try #require(await updater.find())
        device.connection.close()
        #expect(device.flashChipID == FM1FlashChip.uc25hq80)
        let older = FM1Updater(
            transport: SimulatedFM1(options: UpdaterTests.fastOptions), timing: UpdaterTests.fastTiming)
        let olderDevice = try #require(await older.find())
        olderDevice.connection.close()
        #expect(olderDevice.flashChipID == nil)
        #expect(try await updater.summary()?.hasNewerFlashChip == true)
        #expect(await older.devices().first?.hasNewerFlashChip == false)
    }
}

extension FlashChipTests {
    @Test func readsNoChipFromAnIdentityThatRunsIntoIt() throws {
        let loader = try #require(FM1Identity(text: "ota-FM1C_db1642b2b6fa5c2c"))
        let reply = loader.handshakeReply(flashChipID: FM1FlashChip.uc25hq80)
        #expect(FM1Identity(handshakeReply: reply) == loader)
        #expect(FM1Identity.flashChipID(inHandshakeReply: reply) == nil)
    }
}

/// Firmwares built on felucca-bsp since November 2026 shorten their handshake answer for
/// M-UPGRADE, and give the whole identity when asked for it.
struct ShortenedIdentityTests {
    @Test func theQueriesAreTheDocumentedOnes() {
        #expect(FM1Message.command(FM1Message.identityCommand) == FM1Message.handshakeQuery)
        let full = FM1Message.parseCommand(FM1Message.fullIdentityQuery)
        #expect(full?.command == 0x11)
        #expect(full?.payload == [1])
    }

    @Test func asksForTheWholeIdentityAfterAShortenedOne() async throws {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = try #require(FM1Identity(text: "FM-1_1234567"))
        options.shortensIdentity = true
        options.flashChipID = FM1FlashChip.uc25hq80
        let updater = FM1Updater(transport: SimulatedFM1(options: options), timing: UpdaterTests.fastTiming)
        let device = try #require(await updater.find())
        device.connection.close()
        #expect(device.identity.text == "FM-1_1234567")
        #expect(device.flashChipID == FM1FlashChip.uc25hq80)
    }

    @Test func asksForTheFlashChipWhenThePlainAnswerLeavesItOut() async throws {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = try #require(FM1Identity(text: "FM-1_378000"))
        options.reportsFlashChipOnlyWhenAsked = true
        options.flashChipID = FM1FlashChip.uc25hq80
        let device = SimulatedFM1(options: options)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        let summary = try #require(await updater.summary())
        #expect(summary.identity.text == "FM-1_378000")
        #expect(summary.hasNewerFlashChip)
    }

    @Test func asksNoMoreOfAWholeIdentityThatCarriesTheChip() throws {
        let identity = try #require(FM1Identity(text: "FM-1_378000"))
        #expect(identity.mayTellMore(thanAnswerWith: FM1FlashChip.p25q80) == false)
        #expect(identity.mayTellMore(thanAnswerWith: nil))
        #expect(try #require(FM1Identity(text: "FM-1_900")).mayTellMore(thanAnswerWith: FM1FlashChip.p25q80))
        #expect(FM1Identity.officialV16.mayTellMore(thanAnswerWith: nil) == false)
        #expect(try #require(FM1Identity(text: "ota-FM-1_378000")).mayTellMore(thanAnswerWith: nil) == false)
    }

    @Test func keepsAThreeDigitIdentityWhenNothingMoreComes() async throws {
        let updater = FM1Updater(
            transport: SimulatedFM1(options: UpdaterTests.fastOptions), timing: UpdaterTests.fastTiming)
        #expect(await updater.identify()?.text == "FM-1_900")
        #expect(FM1Identity.officialV15.mayBeShortened == false)
        #expect(try #require(FM1Identity(text: "ota-FM-1_900")).mayBeShortened == false)
    }
}
