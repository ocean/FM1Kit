import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// Restoring V15's factory voices.
struct VoiceRestoreTests {
    static let v15 = FM1Identity.officialV15
    static let voices = (0..<FwscPackage.factoryVoicesLength).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 3) }

    static func device(_ change: (inout SimulatedFM1.Options) -> Void = { _ in }) -> SimulatedFM1 {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = v15
        change(&options)
        return SimulatedFM1(options: options)
    }

    static var timing: UpdaterTiming {
        var timing = UpdaterTests.fastTiming
        timing.voiceReplyWait = .milliseconds(200)
        return timing
    }

    @Test func writesEveryBankAndReportsProgress() async throws {
        let device = Self.device()
        let fractions = OSAllocatedUnfairLock(initialState: [Double]())
        try await FM1Updater(transport: device, timing: Self.timing).restoreVoices(Self.voices) { fraction in
            fractions.withLock { $0.append(fraction) }
        }
        #expect(device.currentVoices == Self.voices)
        let reported = fractions.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(reported.count == 1 + FwscPackage.factoryVoicesLength / FM1Message.voiceWriteLength)
    }

    @Test func needsTheIdentityARealV15Reports() {
        #expect(FM1Identity.officialV15.text == "FM-1_015")
        #expect(FM1Identity.officialV15 == FM1Identity(text: "FM-1_015"))
    }

    @Test func sendsTheSameMessagesAsMVAVEsUpdater() {
        // The bytes M-VAVE's updater builds for bank 2's erase and the write at 0x2200.
        #expect(FM1Updater.voiceAddress(0x2000) == [5, 0x00, 0x20, 0, 0])
        #expect(
            FM1Updater.voiceAddress(0x2200) + FM1Message.littleEndian(512, byteCount: 3) == [
                5, 0x00, 0x22, 0, 0, 0, 2, 0,
            ])
    }

    @Test func refusesAnyFirmwareButV15() async throws {
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        await #expect(throws: FM1UpdateError.voiceRestoreNeedsV15(device: "FM-1_900")) {
            try await FM1Updater(transport: device, timing: Self.timing).restoreVoices(Self.voices) { _ in }
        }
    }

    @Test func refusesTheLoader() async throws {
        let device = Self.device { $0.startsInRecoveryMode = true }
        await #expect(throws: FM1UpdateError.voiceRestoreNeedsV15(device: "ota-FM-1_9")) {
            try await FM1Updater(transport: device, timing: Self.timing).restoreVoices(Self.voices) { _ in }
        }
    }

    @Test func refusesAPackageThatIsNotV15() async throws {
        let device = Self.device()
        await #expect(throws: FM1UpdateError.factoryVoicesUnavailable) {
            try await FM1Updater(transport: device, timing: Self.timing)
                .restoreFactoryVoices(from: try UpdaterTests.package(product: "FM-1_015"))
        }
        #expect(device.events.isEmpty)
    }

    @Test func stopsWhenV15RefusesAStep() async throws {
        let device = Self.device { $0.voiceReply = 4 }
        await #expect(throws: FM1UpdateError.voiceRestoreRefused(code: 4, bytesWritten: 0)) {
            try await FM1Updater(transport: device, timing: Self.timing).restoreVoices(Self.voices) { _ in }
        }
    }

    @Test func anInterruptedRestoreFinishesWhenRunAgain() async throws {
        // Erase bank 0, write its 8 blocks, erase bank 1, then write one block of it.
        let device = Self.device { $0.stopsAnsweringVoicesAfter = 11 }
        let updater = FM1Updater(transport: device, timing: Self.timing)
        await #expect(throws: FM1UpdateError.voiceRestoreStalled(bytesWritten: 4096 + 512)) {
            try await updater.restoreVoices(Self.voices) { _ in }
        }
        #expect(device.currentVoices != Self.voices)

        let fresh = Self.device { $0.initialVoices = device.currentVoices }
        try await FM1Updater(transport: fresh, timing: Self.timing).restoreVoices(Self.voices) { _ in }
        #expect(fresh.currentVoices == Self.voices)
    }

    @Test func readsTheVoicesFromAPackagesUserData() throws {
        let user = FwscPackage.SamplePart(type: 50, name: "USR", size: 16_400, storedSize: 16_416, isEnciphered: true)
        let image = FwscPackage.sampleImage(parts: [.flash(), user, .loader()])
        let package = try FwscPackage(bytes: FwscPackage.sampleFile(logicalImage: image, product: "FM-1_015"))
        let part = try #require(package.container.userData)
        let expected = Array(
            FwscPackage.decipherUserData(image, range: part.offset..<(part.offset + part.storedSize)).prefix(16_384))
        #expect(package.voices(matching: FwscPackage.sha256Hex(expected)) == expected)
        #expect(package.voices(matching: FwscPackage.factoryVoicesSHA256) == nil)
        // Only M-VAVE's official V15 package can restore the voices.
        #expect(!package.hasFactoryVoices)
    }
}
