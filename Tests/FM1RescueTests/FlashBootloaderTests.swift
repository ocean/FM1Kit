@_spi(Testing) import FM1Kit
import Testing

@testable import FM1Rescue

/// Planning bootloader changes on the boot areas FM-1s have: V15's, V16's and m-bootloader 2's,
/// and on the newer flash chip.
struct FlashBootloaderTests {
    @Test func readsTheClockAndWhereTheConfigurationIs() throws {
        let v15 = try #require(
            FlashPlan.bootConfiguration(
                SampleFlash.bootArea(
                    holding: SampleFlash.stockBootloader(), configuration: SampleFlash.configuration(clock: 360_000_000)
                )))
        #expect(v15.start == 0x38D0)
        #expect(v15.clock == 360_000_000)
        #expect(v15.minimumMBootloader == nil)
        let v16 = try #require(FlashPlan.bootConfiguration(Self.v16BootArea()))
        #expect(v16.start == 0x3938)
        #expect(v16.clock == 320_000_000)
        #expect(v16.minimumMBootloader == "1.3")
    }

    @Test func installsM_BootloaderOverV16sBootloader() throws {
        let original = SampleFlash.flash(
            configurationAt: SampleFlash.v16Configuration,
            configuration: SampleFlash.configuration(clock: 320_000_000, length: 0x2F3))
        let chip = SimulatedDownloadMode(flash: original)
        let session = try FlashSession(connection: chip)
        let plan = try FlashPlan.installing(BootloaderImage.sample(version: "1.3-sample"), onto: session.backUp())
        try session.write(plan)
        let after = try session.backUp()
        #expect(after.mBootloader == .sample(version: "1.3-sample"))
        #expect(after.bytes[SampleFlash.v16Configuration..<0x4000] == original[SampleFlash.v16Configuration..<0x4000])
        #expect(after.bytes[0x4000...] == original[0x4000...])
    }

    @Test func refusesAnM_BootloaderThatWouldStopAtBadConfig() throws {
        let v16 = SampleFlash.backup(
            SampleFlash.flash(
                configurationAt: SampleFlash.v16Configuration,
                configuration: SampleFlash.configuration(clock: 320_000_000, length: 0x2F3)))
        #expect(throws: FlashPlanError.bootloaderTooOld("1.2-sample", minimum: "1.3")) {
            try FlashPlan.installing(BootloaderImage.sample(version: "1.2-sample"), onto: v16)
        }
        let shortened = SampleFlash.backup(Self.shortenedFlash())
        #expect(throws: FlashPlanError.bootloaderTooOld("1.3-sample", minimum: "2.0")) {
            try FlashPlan.installing(BootloaderImage.sample(version: "1.3-sample"), onto: shortened)
        }
        let plan = try FlashPlan.installing(BootloaderImage.sample(version: "2.1-sample"), onto: shortened)
        let configuration = SampleFlash.shortenedConfiguration..<0x4000
        #expect(plan.target[configuration] == shortened.bytes[configuration])
    }

    @Test func putsBackThePackagesWholeBootArea() throws {
        let stock = SampleFlash.flash()
        let package = try SampleFlash.package(stock)
        let chip = SimulatedDownloadMode(flash: Self.shortenedFlash())
        let session = try FlashSession(connection: chip)
        try session.write(try FlashPlan.installingBootloader(from: package, onto: session.backUp()))
        #expect(chip.flash[0..<0x4000] == stock[0..<0x4000])
        #expect(chip.flash[0x4000...] == Self.shortenedFlash()[0x4000...])
    }

    @Test func takesTheNewerFlashChipForAnFM1s() throws {
        let blank = SimulatedDownloadMode.sampleFlash()
        let restore = try FlashPlan.restoring(
            SampleFlash.backup(SampleFlash.flash()), onto: SampleFlash.backup(blank, flashID: 0xB3_6014))
        #expect(restore.warnings.contains { $0.contains("its flash chip is the FM-1's") })
        let chip = SimulatedDownloadMode(flash: SampleFlash.flash())
        chip.flashID = 0xB3_6014
        let session = try FlashSession(connection: chip)
        let current = try session.backUp()
        #expect(current.flashID == FM1FlashChip.uc25hq80)
        let plan = try FlashPlan.installing(BootloaderImage.sample(), onto: current)
        #expect(plan.warnings.contains { $0.contains("the newer flash chip (0xB36014)") })
    }

    /// V16's boot area: its bootloader is larger, so its configuration starts further on.
    static func v16BootArea() -> [UInt8] {
        SampleFlash.bootArea(
            holding: SampleFlash.stockBootloader(),
            configurationAt: SampleFlash.v16Configuration,
            configuration: SampleFlash.configuration(clock: 320_000_000, length: 0x2F3))
    }

    /// Flash with m-bootloader 2, whose install keeps only the 34-byte chip-key record of the
    /// configuration, at the end of the boot area.
    static func shortenedFlash() -> [UInt8] {
        SampleFlash.flash(
            bootloader: BootloaderImage.sample(version: "2.1-sample").bytes,
            configurationAt: SampleFlash.shortenedConfiguration,
            configuration: [UInt8](repeating: 0x3C, count: 34))
    }
}
