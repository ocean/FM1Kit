import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// Checking a package's container before anything reaches the device.
struct PackageCheckTests {
    static func read(_ image: [UInt8]) throws(FwscPackage.Failure) -> FwscPackage {
        try FwscPackage(bytes: FwscPackage.sampleFile(logicalImage: image, product: "FM-1_916"))
    }

    @Test func theChecksumIsCRC16XModem() {
        #expect(FirmwareContainer.crc16(Array("123456789".utf8)) == 0x31C3)
    }

    @Test func decipheringTwiceGivesBackTheOriginal() {
        let bytes = (0..<80).map { UInt8($0) }
        #expect(FirmwareContainer.decipher(bytes) != bytes)
        #expect(FirmwareContainer.decipher(FirmwareContainer.decipher(bytes)) == bytes)
    }

    @Test func readsTheFirmwareImageAndLoader() throws {
        let package = try UpdaterTests.package()
        let container = package.container
        #expect(container.flash.offset == FwscPackage.firstPartOffset)
        #expect(container.flash.size == 32_768)
        #expect(container.loader.name == "ota.bin")
        #expect(package.loaderSHA256 == FwscPackage.sha256Hex(package.logicalImage[container.loader.range]))
        #expect(container.applicationRange == (0x400 + 0x4000)..<(0x400 + 32_768))
    }

    @Test func aFirmwareImageNoBiggerThanTheBootAreaIsAllApplication() throws {
        let package = try Self.read(FwscPackage.sampleImage(parts: [.flash(size: 16_384), .loader()]))
        #expect(package.container.applicationRange == package.container.flash.range)
    }

    @Test func refusesADamagedHeader() {
        var image = FwscPackage.sampleImage(parts: [.flash(), .loader()])
        image[20] ^= 1
        #expect(throws: FwscPackage.Failure.damagedHeader) { try Self.read(image) }
    }

    @Test func refusesADamagedTable() {
        var image = FwscPackage.sampleImage(parts: [.flash(), .loader()])
        image[FirmwareContainer.headerLength + 9] ^= 1
        #expect(throws: FwscPackage.Failure.damagedHeader) { try Self.read(image) }
    }

    @Test func refusesAnotherChip() {
        let image = FwscPackage.sampleImage(parts: [.flash(), .loader()], chip: "BR25")
        #expect(throws: FwscPackage.Failure.unexpectedChip("BR25")) { try Self.read(image) }
    }

    @Test func refusesADamagedPart() {
        var image = FwscPackage.sampleImage(parts: [.flash(), .loader()])
        image[FwscPackage.firstPartOffset + 5_000] ^= 1
        #expect(throws: FwscPackage.Failure.damagedPart("flash.bin")) { try Self.read(image) }
    }

    @Test func doesNotCheckEncipheredParts() throws {
        // M-VAVE's packages carry enciphered extras whose checksums cover the plain bytes.
        let extra = FwscPackage.SamplePart(type: 50, name: "USR", size: 100, storedSize: 112, isEnciphered: true)
        _ = try Self.read(FwscPackage.sampleImage(parts: [.flash(), extra, .loader()]))
    }

    @Test func refusesAPackageWithoutALoader() {
        let image = FwscPackage.sampleImage(parts: [.flash()])
        #expect(throws: FwscPackage.Failure.missingPart("update loader")) { try Self.read(image) }
    }

    @Test func refusesAFirmwareImageThatIsNotWholeSectors() {
        let image = FwscPackage.sampleImage(parts: [.flash(size: 16_385), .loader()])
        #expect(throws: FwscPackage.Failure.missingPart("firmware image")) { try Self.read(image) }
    }

    @Test func refusesOverlappingParts() {
        var loader = FwscPackage.SamplePart.loader()
        loader.offset = FwscPackage.firstPartOffset + 100
        let image = FwscPackage.sampleImage(parts: [.flash(), loader], imageLength: 0x400 + 32_768)
        #expect(throws: FwscPackage.Failure.damagedHeader) { try Self.read(image) }
    }

    @Test func acceptsPaddingPastTheEnd() throws {
        // Felucca 1.6.1's loader is padded to 6944 bytes but its file ends 10 bytes sooner.
        var loader = FwscPackage.SamplePart.loader(size: 990)
        loader.storedSize = 1_000
        let image = FwscPackage.sampleImage(parts: [.flash(), loader], imageLength: 0x400 + 32_768 + 990)
        _ = try Self.read(image)
    }

    @Test func refusesAPartPastTheEnd() {
        let image = FwscPackage.sampleImage(parts: [.flash(), .loader()], imageLength: 0x400 + 32_768 + 990)
        #expect(throws: FwscPackage.Failure.damagedHeader) { try Self.read(image) }
    }

    @Test func refusesAFileTooLargeForAnFM1() {
        let image = FwscPackage.sampleImage(parts: [.flash(), .loader(size: 2_100_000)])
        #expect(throws: FwscPackage.Failure.tooLarge) { try Self.read(image) }
    }
}

/// Write progress counts only the application area.
struct WriteRegionTests {
    @Test func readsOutsideTheRegionLeaveProgressUnchanged() {
        var progress = WriteProgress(region: 1024..<2048)
        // Felucca's loader rewrites the boot area before the application.
        #expect(progress.record(FM1ReadRequest(address: 0, length: 512)) == .writing(fraction: 0, requests: 1))
        #expect(progress.record(FM1ReadRequest(address: 1024, length: 512)) == .writing(fraction: 0.5, requests: 2))
        #expect(progress.record(FM1ReadRequest(address: 4096, length: 16)) == .writing(fraction: 0.5, requests: 3))
        #expect(progress.record(FM1ReadRequest(address: 1536, length: 512)) == .writing(fraction: 1, requests: 4))
    }

    @Test func readsAcrossTheRegionCountOnlyTheirInsidePart() {
        var progress = WriteProgress(region: 1024..<2048)
        #expect(progress.record(FM1ReadRequest(address: 768, length: 512)) == .writing(fraction: 0.25, requests: 1))
    }
}

/// A device that answers the handshake, then sends a fixed script once asked to upgrade.
final class ScriptedTransport: MIDITransport, Sendable {
    let connection: ScriptedConnection

    init(identity: FM1Identity, script: [[UInt8]]) {
        connection = ScriptedConnection(identity: identity, script: script)
    }

    func ports() async -> [MIDIPortDescriptor] { [connection.port] }
    func open(_: MIDIPortDescriptor) async throws -> any MIDIConnection { connection }
    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

final class ScriptedConnection: MIDIConnection, Sendable {
    let port = MIDIPortDescriptor(id: "scripted", name: "FM-1 Midi")
    let identity: FM1Identity
    let script: [[UInt8]]
    let inbox = SysexInbox()
    let sent = OSAllocatedUnfairLock(initialState: [[UInt8]]())
    var isLost: Bool { false }

    init(identity: FM1Identity, script: [[UInt8]]) {
        self.identity = identity
        self.script = script
    }

    func send(_ sysex: [UInt8]) throws {
        sent.withLock { $0.append(sysex) }
        if sysex == FM1Message.handshakeQuery {
            inbox.deliver(identity.handshakeReply())
        } else if sysex == FM1Message.upgradeCommand {
            script.forEach(inbox.deliver)
        }
    }

    func receive(timeout: Duration) async -> [UInt8]? { await inbox.next(timeout: timeout) }
    func drain() { inbox.drain() }
    func close() {}

    /// How many finish replies were sent.
    var finishReplies: Int {
        sent.withLock { sent in sent.filter { FM1ReadRequest.parseResponse($0)?.request.isFinish == true }.count }
    }
}

/// How each half of an update ends.
struct FinishTests {
    static let stagingFinish = FM1ReadRequest(address: FM1Message.stageFinishAddress, length: 8).encoded()
    static let writingFinish = FM1ReadRequest(address: FM1Message.writeFinishAddress, length: 8).encoded()
    static let loader = FM1Identity(model: "ota-FM-1", version: 15)
    static let firmware = FM1Identity(model: "FM-1", version: 900)

    static var timing: UpdaterTiming {
        var timing = UpdaterTests.fastTiming
        timing.finishSettle = .milliseconds(200)
        timing.returnSearch = .milliseconds(100)
        return timing
    }

    @Test func aRepeatedFinishIsAnsweredBeforeThePortCloses() async throws {
        let transport = ScriptedTransport(identity: Self.loader, script: [Self.writingFinish, Self.writingFinish])
        let updater = FM1Updater(transport: transport, timing: Self.timing)
        // The scripted loader never reboots, so the update ends waiting for the device.
        await #expect(throws: FM1UpdateError.deviceDidNotReturn) {
            try await updater.resume(try UpdaterTests.package())
        }
        #expect(transport.connection.finishReplies == 2)
    }

    @Test func finishingWritingWhileStagingStopsTheUpdate() async throws {
        let transport = ScriptedTransport(identity: Self.firmware, script: [Self.writingFinish])
        let updater = FM1Updater(transport: transport, timing: Self.timing)
        await #expect(throws: FM1UpdateError.unexpectedFinish(phase: .staging)) {
            try await updater.install(try UpdaterTests.package(), options: .confirmed)
        }
        #expect(transport.connection.finishReplies == 0)
    }

    @Test func finishingStagingWhileWritingStopsTheUpdate() async throws {
        let transport = ScriptedTransport(identity: Self.loader, script: [Self.stagingFinish])
        let updater = FM1Updater(transport: transport, timing: Self.timing)
        await #expect(throws: FM1UpdateError.unexpectedFinish(phase: .writing)) {
            try await updater.resume(try UpdaterTests.package())
        }
        #expect(transport.connection.finishReplies == 0)
    }

    @Test func theStandardTimingsAddNoPauses() {
        #expect(UpdaterTiming.standard.responseDelay == .zero)
        #expect(UpdaterTiming.standard.afterUpgradeCommand == .zero)
    }
}
