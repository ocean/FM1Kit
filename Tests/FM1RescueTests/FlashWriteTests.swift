@_spi(Testing) import FM1Kit
import Testing

@testable import FM1Rescue

/// Planning and writing changes to the flash, against the simulated chip.
struct FlashWriteTests {
    /// The FM-1's flash, as just read in a session on `chip`.
    static func read(_ chip: SimulatedDownloadMode) throws -> (FlashSession, FlashBackup) {
        let session = try FlashSession(connection: chip)
        return (session, try session.backUp())
    }

    @Test func restoresABackupOfTheSameFM1() throws {
        let saved = SampleFlash.flash()
        var changed = saved
        changed.replaceSubrange(0x9_3000..<0x9_3100, with: repeatElement(0x11, count: 0x100))
        changed[0xF_F010] = 0x22
        let chip = SimulatedDownloadMode(flash: changed)
        let (session, current) = try Self.read(chip)
        let plan = try FlashPlan.restoring(SampleFlash.backup(saved), onto: current)
        #expect(plan.sectors == [0x9_3000, 0xF_F000])
        #expect(plan.warnings.count == 1)
        #expect(plan.warnings.first?.hasPrefix("This FM-1's factory data is different from the backup's") == true)
        var fractions: [Double] = []
        try session.write(plan) { fractions.append($0) }
        #expect(chip.flash == saved)
        #expect(chip.erasedSectors == [0x9_3000, 0xF_F000])
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
    }

    @Test func keepsThisFM1sFactoryDataFromAnotherUnitsBackup() throws {
        let saved = SampleFlash.flash()
        var mine = SampleFlash.flash(code: SampleFlash.code(fill: 0x33))
        mine[0xF_F010] = 0x44
        let chip = SimulatedDownloadMode(flash: mine)
        let (session, current) = try Self.read(chip)
        let plan = try FlashPlan.restoring(SampleFlash.backup(saved, uniqueID: "0102030405060708"), onto: current)
        #expect(!plan.warnings.isEmpty)
        try session.write(plan)
        #expect(chip.flash[0..<0xF_F000] == saved[0..<0xF_F000])
        #expect(chip.flash[0xF_F000...] == mine[0xF_F000...])
    }

    @Test func installsM_BootloaderKeepingTheBootConfiguration() throws {
        let original = SampleFlash.flash()
        let chip = SimulatedDownloadMode(flash: original)
        let (session, current) = try Self.read(chip)
        #expect(current.bootloaderDescription == "M-VAVE's")
        let plan = try FlashPlan.installing(BootloaderImage.sample(), onto: current)
        #expect(plan.purpose == .bootloader("m-bootloader 1.2-sample"))
        #expect(plan.sectors.allSatisfy { $0 < 0x4000 })
        try session.write(plan)
        let after = try session.backUp()
        #expect(after.mBootloader == .sample())
        #expect(after.bytes[0x4000...] == original[0x4000...])
        #expect(after.bytes[0..<0x20] == original[0..<0x20])
        #expect(after.bytes[SampleFlash.configuration..<0x4000] == original[SampleFlash.configuration..<0x4000])
        #expect(try FlashPlan.installing(BootloaderImage.sample(), onto: after).isEmpty)
    }

    @Test func putsBackTheBootloaderFromAFirmwarePackage() throws {
        let stock = SampleFlash.flash()
        let package = try SampleFlash.package(stock)
        let chip = SimulatedDownloadMode(flash: SampleFlash.flash(bootloader: BootloaderImage.sample().bytes))
        let (session, current) = try Self.read(chip)
        let plan = try FlashPlan.installingBootloader(from: package, onto: current)
        #expect(plan.purpose == .bootloader("M-VAVE's bootloader"))
        try session.write(plan)
        #expect(chip.flash == stock)
    }

    @Test func refusesABootloaderForAnotherBoard() throws {
        let current = SampleFlash.backup(SampleFlash.flash())
        #expect(throws: FlashPlanError.wrongBoard("smk37")) {
            try FlashPlan.installing(BootloaderImage.sample(board: "smk37"), onto: current)
        }
    }

    @Test func refusesABootAreaWithoutAFileTable() throws {
        let current = SampleFlash.backup(SimulatedDownloadMode.sampleFlash())
        #expect(throws: FlashPlanError.unreadableBootArea) {
            try FlashPlan.installing(BootloaderImage.sample(), onto: current)
        }
    }

    @Test func installsFirmwareKeepingTheBootloaderAndSettings() throws {
        let incoming = SampleFlash.flash(code: SampleFlash.code(fill: 0x77))
        let package = try SampleFlash.package(incoming)
        var original = SampleFlash.flash(bootloader: BootloaderImage.sample().bytes)
        original[0x9_3000] = 0x01
        let chip = SimulatedDownloadMode(flash: original)
        let (session, current) = try Self.read(chip)
        let plan = try FlashPlan.installing(package, onto: current)
        #expect(plan.purpose == .firmware(package.identity))
        #expect(plan.sectors.allSatisfy { (0x4000..<0x8000).contains($0) })
        #expect(plan.warnings.isEmpty)
        try session.write(plan)
        let after = try session.backUp()
        #expect(after.mBootloader == .sample())
        #expect(after.bytes[0x4000..<0x8000] == incoming[0x4000..<0x8000])
        #expect(after.bytes[0x9_3000] == 0x01)
        #expect(after.firmware.files == .intact)
    }

    @Test func installsFirmwareWithItsBootloaderAndErasesItsSettings() throws {
        let incoming = SampleFlash.flash(code: SampleFlash.code(fill: 0x77))
        let package = try SampleFlash.package(incoming)
        var original = SampleFlash.flash(bootloader: BootloaderImage.sample().bytes)
        original[0x9_3000] = 0x01
        let chip = SimulatedDownloadMode(flash: original)
        let (session, current) = try Self.read(chip)
        let plan = try FlashPlan.installing(
            package, onto: current, includingBootloader: true, erasingSettings: true)
        try session.write(plan)
        #expect(chip.flash[0..<0x8000] == incoming[0..<0x8000])
        #expect(chip.flash[0x9_3000..<0x9_5000].allSatisfy { $0 == 0xFF })
        #expect(chip.flash[0x9_5000...] == original[0x9_5000...])
    }

    @Test func warnsWhenTheFirmwareKeepsItsSettingsElsewhere() throws {
        let incoming = SampleFlash.flash(regions: [("VM", 0xA_0000..<0xA_2000)])
        let current = SampleFlash.backup(SampleFlash.flash())
        let plan = try FlashPlan.installing(try SampleFlash.package(incoming), onto: current)
        #expect(plan.warnings.count == 1)
    }

    @Test func refusesFirmwareMadeForAnotherChipKey() throws {
        let package = try FwscPackage(data: FwscPackage.sampleFile(product: "FM-1_378001"))
        #expect(throws: FlashPlanError.wrongChipKey(0x980F)) {
            try FlashPlan.installing(package, onto: SampleFlash.backup(SampleFlash.flash()))
        }
    }

    @Test func refusesWhenTheFlashChangedSinceItWasRead() throws {
        let chip = SimulatedDownloadMode(flash: SampleFlash.flash())
        let (session, current) = try Self.read(chip)
        let stale = SampleFlash.backup(SampleFlash.flash(code: SampleFlash.code(fill: 0x33)))
        let plan = try FlashPlan.installing(BootloaderImage.sample(), onto: stale)
        #expect(throws: DownloadModeError.flashChanged) { try session.write(plan) }
        #expect(chip.flash == current.bytes)
        #expect(chip.erasedSectors.isEmpty)
    }

    @Test func stopsWhenARunDoesntReadBackAsWritten() throws {
        let chip = SimulatedDownloadMode(flash: SampleFlash.flash())
        let (session, current) = try Self.read(chip)
        let plan = try FlashPlan.installing(BootloaderImage.sample(), onto: current)
        chip.failsWritesAt = 0xA0
        #expect(throws: DownloadModeError.writeNotVerified(0..<0x1000)) { try session.write(plan) }
        #expect(chip.erasedSectors == [0, 0])
    }

    @Test func showsProgressOnTheFM1sScreen() throws {
        let chip = SimulatedDownloadMode(flash: SampleFlash.flash())
        let (session, current) = try Self.read(chip)
        try session.write(try FlashPlan.installing(BootloaderImage.sample(), onto: current))
        #expect(chip.screen[3] == " BOOTLOADER")
        #expect(chip.screen[5] == " DONE - VERIFIED")
        #expect(chip.progressBar == 100)
    }
}
