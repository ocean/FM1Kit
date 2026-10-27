import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// M-VAVE's open firmware: capability, arming, and the messages that carry them.
struct OpenFirmwareTests {
    static let open = FM1Identity(model: "FM-1", version: 8_000_012)
    static let newBuild = FM1BuildID(bytes: (0..<32).map { UInt8($0) })

    static func device(_ change: (inout SimulatedFM1.Options) -> Void = { _ in }) -> SimulatedFM1 {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = open
        change(&options)
        return SimulatedFM1(options: options)
    }

    @Test func buildIDsReadHexInEitherCase() throws {
        let text = String(repeating: "0a", count: 32)
        let id = try #require(FM1BuildID(hex: text.uppercased()))
        #expect(id.bytes == [UInt8](repeating: 10, count: 32))
        #expect(id.hex == text)
        #expect(FM1BuildID(hex: String(text.dropLast())) == nil)
        #expect(FM1BuildID(hex: String(text.dropLast()) + "g") == nil)
    }

    @Test func commandsRoundTrip() throws {
        let message = FM1Message.command(FM1Message.armCommand, payload: [1, 2, 3])
        let parsed = try #require(FM1Message.parseCommand(message))
        #expect(parsed.command == FM1Message.armCommand)
        #expect(parsed.payload == [1, 2, 3])
        #expect(FM1Message.parseCommand(FM1Message.command(FM1Message.capabilityCommand))?.payload.isEmpty == true)
        var damaged = message
        damaged[damaged.count - 2] ^= 1
        #expect(FM1Message.parseCommand(damaged) == nil)
    }

    @Test func capabilitiesRoundTripAndRejectOtherLayouts() {
        let capability = FM1Capability(state: 2, buildID: Self.newBuild, errorCode: 5)
        #expect(FM1Capability(payload: capability.payload()) == capability)
        #expect(capability.payload().count == 47)
        #expect(!capability.isReady)
        var otherMagic = capability.payload()
        otherMagic[0] = UInt8(ascii: "X")
        #expect(FM1Capability(payload: otherMagic) == nil)
        #expect(FM1Capability(payload: Array(capability.payload().dropLast())) == nil)
    }

    @Test func recognisesOpenFirmwareIdentities() {
        #expect(Self.open.isOpenFirmware)
        #expect(FM1Identity(text: "FM1_COMMUNITY_3")?.isOpenFirmware == true)
        #expect(FM1Identity(text: "FM-1_015")?.isOpenFirmware == false)
        #expect(FM1Identity(text: "FM-1_916")?.isOpenFirmware == false)
        #expect(FM1Identity(text: "FM-1_8000014")?.isOpenFirmware == true)
        #expect(FM1Identity(text: "FM-1_8010300")?.isOpenFirmware == false)
        #expect(FM1Identity(text: "ota-FM-1_015")?.isOpenFirmware == false)
    }

    @Test func readsAnArmedOpenFirmwareLoader() throws {
        // The reply a real FM-1 sent after Open V12 was armed with V15's build ID (2026-10-17).
        let reply: [UInt8] = [
            0xF0, 0x00, 0x32, 0x45, 0x58, 0x01, 0x00, 0x40, 0x37, 0x74, 0x42, 0x35, 0x31, 0x54, 0x29, 0x4C, 0x21,
            0x5F, 0x48, 0x09, 0x0B, 0x63, 0x06, 0x0D, 0x19, 0x62, 0x64, 0x08, 0x33, 0x63, 0x2C, 0x58, 0x1A, 0x63,
            0x64, 0x0C, 0x03, 0x00, 0x20, 0x1D, 0xF7,
        ]
        let identity = try #require(FM1Identity(handshakeReply: reply))
        #expect(identity.text == "ota-FM1C_db1642b2b6fa5c2c")
        #expect(identity.isLoader)
        #expect(identity.hardwareModel == "FM-1")
        #expect(identity.isLoader(for: "FM-1"))
        #expect(identity.armedBuildPrefix == String(OfficialFirmware.v15.buildID.hex.prefix(16)))
        #expect(FM1Identity(text: "ota-FM1C_db1642b2") == nil)
        #expect(FM1Identity(text: "FM-1_916")?.armedBuildPrefix == nil)
    }

    @Test func armsOpenFirmwareAndChecksTheBuildAfterwards() async throws {
        let device = Self.device()
        let package = try UpdaterTests.package(product: "FM-1_8000013")
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        #expect(try await updater.check(package).kind == .update)
        // A new build of the same firmware needs no confirmation.
        let installed = try await updater.install(package, options: InstallOptions(buildID: Self.newBuild))
        #expect(installed.text == "FM-1_8000013")
        #expect(device.currentBuildID == Self.newBuild)
    }

    @Test func armsWithThePackageHashWithoutABuildID() async throws {
        let device = Self.device()
        let package = try UpdaterTests.package(product: "FM-1_8000013")
        device.prepare(for: package)
        try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming).install(package)
        #expect(device.currentBuildID.hex == package.sha256)
    }

    @Test func theRunningBuildIsAReinstall() async throws {
        let device = Self.device { $0.installedBuildID = Self.newBuild }
        let package = try UpdaterTests.package(product: "FM-1_8000013")
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        #expect(try await updater.check(package, buildID: Self.newBuild).kind == .reinstall)
        await #expect(throws: FM1UpdateError.alreadyInstalled("FM-1_8000012")) {
            try await updater.install(package, options: InstallOptions(buildID: Self.newBuild))
        }
    }

    @Test func leavingOpenFirmwareIsASwitch() async throws {
        let device = Self.device()
        let package = try UpdaterTests.package(product: "FM-1_015")
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        #expect(try await updater.check(package).kind == .switchingFirmware)
        await #expect(throws: FM1UpdateError.switchNotConfirmed(device: "FM-1_8000012", package: "FM-1_015")) {
            try await updater.install(package)
        }
        #expect(try await updater.install(package, options: .confirmed).text == "FM-1_015")
    }

    @Test func aBusyDeviceIsNotArmed() async throws {
        let device = Self.device { $0.capabilityState = 1 }
        let package = try UpdaterTests.package(product: "FM-1_8000013")
        device.prepare(for: package)
        await #expect(throws: FM1UpdateError.deviceBusy) {
            try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming).install(package)
        }
    }

    @Test func aRefusedArmingStopsBeforeStaging() async throws {
        let device = Self.device { $0.armReply = 3 }
        let package = try UpdaterTests.package(product: "FM-1_8000013")
        device.prepare(for: package)
        await #expect(throws: FM1UpdateError.armRefused(code: 3)) {
            try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming).install(package)
        }
        #expect(device.currentIdentity == Self.open)
    }

    @Test func openFirmwareThatDoesNotAnswerIsNotUpdated() async throws {
        var timing = UpdaterTests.fastTiming
        timing.commandReplyWait = .milliseconds(100)
        let transport = ScriptedTransport(identity: Self.open, script: [])
        let updater = FM1Updater(transport: transport, timing: timing)
        await #expect(throws: FM1UpdateError.capabilityUnavailable) {
            try await updater.install(try UpdaterTests.package(product: "FM-1_8000013"))
        }
        #expect(!transport.connection.sent.withLock { $0 }.contains(FM1Message.upgradeCommand))
    }

    @Test func otherFirmwaresAreNotAskedAboutCapability() async throws {
        let transport = ScriptedTransport(identity: FM1Identity(model: "FM-1", version: 916), script: [])
        let check = try await FM1Updater(transport: transport, timing: UpdaterTests.fastTiming)
            .check(try UpdaterTests.package(product: "FM-1_015"))
        #expect(check.capability == nil)
        #expect(transport.connection.sent.withLock { $0 } == [FM1Message.handshakeQuery])
    }

    @Test func officialReleasesCarryTheirBuildIDs() {
        #expect(OfficialFirmware.v15.buildID.hex == OfficialFirmware.v15.sha256)
        #expect(OfficialFirmware.openV12.buildID.hex.hasPrefix("426b7fa5"))
        #expect(OfficialFirmware.known.contains(.openV12))
    }
}

/// Installing a different firmware needs confirming; reinstalling isn't tried.
struct SwitchingFirmwareTests {
    @Test func switchingNeedsConfirmingAndSendsNothingUntilThen() async throws {
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.switchNotConfirmed(device: "FM-1_900", package: "FM-1_916")) {
            try await updater.install(package)
        }
        #expect(device.events.isEmpty)
        #expect(device.currentIdentity?.text == "FM-1_900")
    }

    @Test func aDeviceIsCheckedWithoutChangingIt() async throws {
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        let check = try await updater.check(try UpdaterTests.package(product: "FM-1_900"))
        #expect(check.device.text == "FM-1_900")
        #expect(check.kind == .sameIdentity)
        #expect(device.events.isEmpty)
    }
}

/// Two simulated FM-1s behind one transport.
final class PairTransport: MIDITransport, Sendable {
    let first: SimulatedFM1
    let second: SimulatedFM1

    init(_ first: SimulatedFM1, _ second: SimulatedFM1) {
        self.first = first
        self.second = second
    }

    func ports() async -> [MIDIPortDescriptor] {
        let one = await first.ports().map { port in Self.port(port, prefix: "1-") }
        let two = await second.ports().map { port in Self.port(port, prefix: "2-") }
        return one + two
    }

    /// The port as this transport lists it, its identifier prefixed with the device's.
    static func port(_ port: MIDIPortDescriptor, prefix: String) -> MIDIPortDescriptor {
        MIDIPortDescriptor(id: prefix + port.id, name: port.name, serialNumber: port.serialNumber)
    }

    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection {
        let device = port.id.hasPrefix("1-") ? first : second
        return try await device.open(
            MIDIPortDescriptor(id: String(port.id.dropFirst(2)), name: port.name, serialNumber: port.serialNumber))
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// The updater refuses to start while more than one FM-1 answers.
struct MultipleDeviceTests {
    @Test func refusesToInstallWithTwoFM1sConnected() async throws {
        let first = SimulatedFM1(options: UpdaterTests.fastOptions)
        let second = SimulatedFM1(options: UpdaterTests.fastOptions)
        let updater = FM1Updater(transport: PairTransport(first, second), timing: UpdaterTests.fastTiming)
        let package = try UpdaterTests.package()
        await #expect(throws: FM1UpdateError.multipleDevices(count: 2)) {
            try await updater.install(package, options: .confirmed)
        }
        await #expect(throws: FM1UpdateError.multipleDevices(count: 2)) { try await updater.check(package) }
        #expect(first.events.isEmpty && second.events.isEmpty)
    }

    @Test func refusesToResumeWithTwoLoadersWaiting() async throws {
        var options = UpdaterTests.fastOptions
        options.startsInRecoveryMode = true
        let updater = FM1Updater(
            transport: PairTransport(SimulatedFM1(options: options), SimulatedFM1(options: options)),
            timing: UpdaterTests.fastTiming
        )
        await #expect(throws: FM1UpdateError.multipleDevices(count: 2)) {
            try await updater.resume(try UpdaterTests.package())
        }
    }

    @Test func findAllReportsEveryDevice() async {
        let updater = FM1Updater(
            transport: PairTransport(
                SimulatedFM1(options: UpdaterTests.fastOptions), SimulatedFM1(options: UpdaterTests.fastOptions)),
            timing: UpdaterTests.fastTiming
        )
        let found = await updater.findAll()
        #expect(found.map(\.identity.text) == ["FM-1_900", "FM-1_900"])
        for device in found {
            device.connection.close()
        }
    }

    @Test func listsEveryDeviceForAPersonToChoose() async {
        var v15 = UpdaterTests.fastOptions
        v15.installedIdentity = .officialV15
        let updater = FM1Updater(
            transport: PairTransport(SimulatedFM1(options: UpdaterTests.fastOptions), SimulatedFM1(options: v15)),
            timing: UpdaterTests.fastTiming
        )
        let devices = await updater.devices()
        #expect(devices.map(\.identity.text) == ["FM-1_900", "FM-1_015"])
        #expect(devices.map(\.firmwareName) == [nil, "M-VAVE V15"])
        #expect(Set(devices.map(\.id)).count == 2)
    }

    @Test func installsOnTheDeviceChosenAndLeavesTheOtherAlone() async throws {
        let first = SimulatedFM1(options: UpdaterTests.fastOptions)
        let second = SimulatedFM1(options: UpdaterTests.fastOptions)
        let package = try UpdaterTests.package()
        second.prepare(for: package)
        let transport = PairTransport(first, second)
        let devices = await FM1Updater(transport: transport, timing: UpdaterTests.fastTiming).devices()
        let chosen = try #require(devices.last)
        let updater = FM1Updater(transport: transport, timing: UpdaterTests.fastTiming, device: chosen)
        #expect(await updater.devices().map(\.id) == [chosen.id])
        let installed = try await updater.install(package, options: .confirmed)
        #expect(installed.text == package.product)
        #expect(first.events.isEmpty)
        #expect(!second.events.isEmpty)
    }

    @Test func choosingADeviceGivesAdviceToChoose() {
        #expect(FM1Advice(for: FM1UpdateError.multipleDevices(count: 2)).action == .chooseDevice)
    }
}

/// The sample packages apps can build for their own tests.
struct SamplePackageTests {
    @Test func aSampleFilePassesEveryCheck() throws {
        let package = try FwscPackage(data: FwscPackage.sampleFile(product: "FM-1_123", flashSize: 65_536))
        #expect(package.product == "FM-1_123")
        #expect(package.container.applicationRange == 0x4400..<(0x400 + 65_536))
    }
}
