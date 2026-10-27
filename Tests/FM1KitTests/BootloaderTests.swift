import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// Reading m-bootloader's installer packages, and installing it over USB-MIDI.
struct BootloaderTests {
    static func installer(_ bootloader: BootloaderImage = .sample()) throws -> BootloaderInstaller {
        let package = try FwscPackage(data: FwscPackage.sampleBootloaderInstallerFile(carrying: bootloader))
        return try BootloaderInstaller(package: package)
    }

    static func device(
        running identity: FM1Identity = .officialV15,
        bootloader: String? = nil,
        comparesBootArea: Bool = false,
        refusesAfterHeader: Bool = false
    ) -> SimulatedFM1 {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = identity
        options.bootloaderVersion = bootloader
        options.comparesBootArea = comparesBootArea
        options.refusesAfterHeader = refusesAfterHeader
        return SimulatedFM1(options: options)
    }

    @Test func readsTheBootloaderAnInstallerCarries() throws {
        let installer = try Self.installer()
        #expect(!installer.package.isFirmware)
        #expect(installer.package.product == "FM-1_099")
        #expect(installer.bootloader == .sample())
        #expect(installer.bootloader.board == "fm1")
        #expect(installer.bootloader.version == "1.2-sample")
    }

    @Test func refusesFirmwareAsAnInstaller() throws {
        let package = try UpdaterTests.package()
        #expect(package.isFirmware)
        #expect(throws: BootloaderInstaller.Failure.notAnInstaller) { try BootloaderInstaller(package: package) }
    }

    @Test func refusesABootloaderForAnotherBoard() throws {
        #expect(throws: BootloaderInstaller.Failure.otherBoard("smk37")) {
            try Self.installer(.sample(board: "smk37"))
        }
    }

    @Test func refusesADamagedInstaller() throws {
        let installer = try Self.installer()
        var stream = Array(installer.package.logicalImage[installer.package.container.loader.range])
        #expect(StagedUpdater.decode(stream[...]) != nil)
        stream[200] ^= 1
        #expect(StagedUpdater.decode(stream[...]) == nil)
    }

    @Test func checksABootloaderContainer() {
        var bytes = BootloaderImage.sample().bytes
        #expect(BootloaderImage(bytes: bytes) != nil)
        bytes[100] ^= 1
        #expect(BootloaderImage(bytes: bytes) == nil)
    }

    @Test func decodesLZ4MatchesThatOverlap() {
        // "ab", then 6 bytes from 2 back, then "c".
        var output: [UInt8] = []
        let block: [UInt8] = [0x22, 0x61, 0x62, 2, 0, 0x10, 0x63]
        #expect(LZ4.decodeBlock(block[...], producing: 9, after: &output))
        #expect(output == Array("ababababc".utf8))
        var short: [UInt8] = []
        #expect(!LZ4.decodeBlock([0x10, 0x61, 9, 0][...], producing: 5, after: &short))
    }

    @Test func installsTheBootloaderAndComesBackOnV15() async throws {
        let device = Self.device()
        let installer = try Self.installer()
        device.prepare(for: installer.package)
        let events = OSAllocatedUnfairLock(initialState: [UpdateEvent]())
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        let identity = try await updater.installBootloader(installer) { event in events.withLock { $0.append(event) } }
        #expect(identity == .officialV15)
        #expect(device.installedBootloaderVersion == "1.2-sample")
        let seen = events.withLock { $0 }
        #expect(seen.first == .connected(.officialV15))
        #expect(seen.contains(.rebooting))
        #expect(seen.last == .finished(.officialV15))
    }

    @Test func installsTheBootloaderOnlyFromV15() async throws {
        let device = Self.device(running: FM1Identity(model: "FM-1", version: 916))
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.bootloaderInstallNeedsV15(device: "FM-1_916")) {
            try await updater.installBootloader(try Self.installer())
        }
        #expect(device.installedBootloaderVersion == nil)
    }

    @Test func sendsTheInstallerToAnyFirmwareWhenAsked() async throws {
        let estampie = FM1Identity(model: "FM-1", version: 378_000)
        let device = Self.device(running: estampie, bootloader: "1.2")
        let installer = try Self.installer()
        device.prepare(for: installer.package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        let identity = try await updater.installBootloader(installer, fromAnyFirmware: true)
        #expect(identity == estampie)
        #expect(device.installedBootloaderVersion == "1.2-sample")
    }

    @Test func explainsAFirmwareRefusingTheInstallerAfterItsHeader() async throws {
        let dub = FM1Identity(model: "FM-1", version: 8_010_300)
        let device = Self.device(running: dub, bootloader: "1.2", refusesAfterHeader: true)
        let installer = try Self.installer()
        device.prepare(for: installer.package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.packageRefused(requests: 2)) {
            try await updater.installBootloader(installer, fromAnyFirmware: true)
        }
        #expect(device.installedBootloaderVersion == "1.2")
    }

    @Test func explainsAFirmwareRefusingAPackageAfterItsHeader() async throws {
        let felucca = FM1Identity(model: "FM-1", version: 916)
        let device = Self.device(running: felucca, refusesAfterHeader: true)
        let package = try UpdaterTests.package(product: "FM-1_015")
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.packageRefused(requests: 2)) {
            try await updater.install(package, options: .confirmed)
        }
        let advice = FM1UpdateError.packageRefused(requests: 2).advice
        #expect(advice.isDeviceFine)
        #expect(advice.action == .needsComputer)
    }

    @Test func refusesToInstallAnInstallerAsFirmware() async throws {
        let updater = FM1Updater(transport: Self.device(), timing: UpdaterTests.fastTiming)
        let package = try Self.installer().package
        await #expect(throws: FM1UpdateError.notFirmware("FM-1_099")) {
            try await updater.install(package, options: .confirmed)
        }
        await #expect(throws: FM1UpdateError.notFirmware("FM-1_099")) { try await updater.check(package) }
    }

    @Test func installingV15PutsM_VAVEsBootloaderBack() async throws {
        let device = Self.device(running: FM1Identity(model: "FM-1", version: 916), bootloader: "1.2")
        let package = try UpdaterTests.package(product: "FM-1_015")
        device.prepare(for: package)
        try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming).install(package, options: .confirmed)
        #expect(device.installedBootloaderVersion == nil)
    }

    @Test func explainsAFirmwareRefusingV15OverM_Bootloader() async throws {
        let dub = FM1Identity(model: "FM-1", version: 8_010_300)
        let device = Self.device(running: dub, bootloader: "1.2", comparesBootArea: true)
        let package = try UpdaterTests.package(product: "FM-1_015")
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.bootloaderMismatch(requests: 3)) {
            try await updater.install(package, options: .confirmed)
        }
        let advice = FM1UpdateError.bootloaderMismatch(requests: 3).advice
        #expect(advice.isDeviceFine)
        #expect(advice.action == .needsComputer)
    }

    @Test func aFirmwareComparingBootAreasTakesV15OverM_VAVEsBootloader() async throws {
        let device = Self.device(running: FM1Identity(model: "FM-1", version: 8_010_300), comparesBootArea: true)
        let package = try UpdaterTests.package(product: "FM-1_015")
        device.prepare(for: package)
        let installed = try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
            .install(package, options: .confirmed)
        #expect(installed == .officialV15)
    }

    @Test func otherFirmwaresKeepTheBootloader() async throws {
        let device = Self.device(bootloader: "1.2")
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming).install(package, options: .confirmed)
        #expect(device.installedBootloaderVersion == "1.2")
    }
}
