@_spi(Testing) import FM1Kit
import Foundation
import Testing

@testable import FM1Rescue

/// How writing erases, chunks, checks and stops, and what planning refuses.
struct FlashWriteSafetyTests {
    /// Flash that differs from `saved` in the given sectors, each filled with `fill`.
    static func flash(_ saved: [UInt8], changing sectors: [Int], to fill: UInt8 = 0x22) -> [UInt8] {
        var changed = saved
        for sector in sectors {
            changed.replaceSubrange(sector..<(sector + 0x1000), with: repeatElement(fill, count: 0x1000))
        }
        return changed
    }

    /// Restores `saved` onto a chip holding `changed`.
    static func restore(_ saved: [UInt8], onto chip: SimulatedDownloadMode) throws {
        let (session, current) = try FlashWriteTests.read(chip)
        try session.write(try FlashPlan.restoring(SampleFlash.backup(saved), onto: current))
    }

    @Test func erasesAlignedRunsInBlocks() throws {
        let saved = SampleFlash.flash()
        let sectors = Array(stride(from: 0x2_0000, to: 0x4_1000, by: 0x1000))
        let chip = SimulatedDownloadMode(flash: Self.flash(saved, changing: sectors))
        try Self.restore(saved, onto: chip)
        #expect(chip.blockErases == 2)
        #expect(chip.erasedSectors.count == 33)
        #expect(chip.flash == saved)
    }

    @Test(arguments: [(4096, 1), (1024, 4), (nil, 8)] as [(Int?, Int)])
    func writesInTheLoadersBufferSize(bufferSize: Int?, writes: Int) throws {
        let saved = Self.flash(SampleFlash.flash(), changing: [0x9_4000], to: 0x11)
        let chip = SimulatedDownloadMode(flash: Self.flash(saved, changing: [0x9_4000]))
        chip.bufferSize = bufferSize
        try Self.restore(saved, onto: chip)
        #expect(chip.flashWrites == writes)
        #expect(chip.flash == saved)
    }

    @Test func skipsChunksThatStayErased() throws {
        var saved = SampleFlash.flash()
        saved.replaceSubrange(0x9_4000..<0x9_4800, with: repeatElement(0x11, count: 0x800))
        saved.replaceSubrange(0x9_4800..<0x9_5000, with: repeatElement(0xFF, count: 0x800))
        let chip = SimulatedDownloadMode(flash: Self.flash(saved, changing: [0x9_4000]))
        chip.bufferSize = 512
        try Self.restore(saved, onto: chip)
        #expect(chip.flashWrites == 4)
        #expect(chip.flash == saved)
    }

    @Test func writesARunOnceMoreWhenItDoesntCheckOut() throws {
        let saved = SampleFlash.flash()
        let chip = SimulatedDownloadMode(flash: Self.flash(saved, changing: [0x9_4000]))
        chip.failsWritesAt = 0x9_4010
        chip.writeFailures = 1
        try Self.restore(saved, onto: chip)
        #expect(chip.erasedSectors == [0x9_4000, 0x9_4000])
        #expect(chip.flash == saved)
    }

    @Test func neverSaysToSwitchOffWhenWritingStops() throws {
        let saved = Self.flash(SampleFlash.flash(), changing: [0x9_4000, 0x9_5000], to: 0x11)
        let chip = SimulatedDownloadMode(flash: Self.flash(saved, changing: [0x9_4000, 0x9_5000]))
        chip.disconnectsAfterWrites = 1
        let error = #expect(throws: DownloadModeError.self) { try Self.restore(saved, onto: chip) }
        #expect(error == .writeInterrupted(at: 0x9_5000, "the device is gone"))
        #expect(error?.errorDescription?.contains("Don't switch the FM-1 off") == true)
    }

    @Test func refusesWhenAnotherFM1IsConnected() throws {
        let chip = SimulatedDownloadMode(flash: SampleFlash.flash())
        let (session, current) = try FlashWriteTests.read(chip)
        let other = SampleFlash.backup(current.bytes, uniqueID: "0102030405060708")
        let plan = try FlashPlan.installing(BootloaderImage.sample(), onto: other)
        #expect(throws: DownloadModeError.flashChanged) { try session.write(plan) }
    }

    @Test func treatsABackupWithoutAUnitIDByItsFactoryData() throws {
        var theirs = SampleFlash.flash()
        theirs[0xF_F020] = 0x01
        let current = SampleFlash.backup(SampleFlash.flash())
        let plan = try FlashPlan.restoring(SampleFlash.backup(theirs, uniqueID: nil), onto: current)
        #expect(plan.warnings.contains { $0.contains("seems to come from another FM-1") })
        #expect(plan.target[0xF_F000...] == current.bytes[0xF_F000...])
        #expect(!plan.sectors.contains(0xF_F000))
    }

    @Test func warnsWhenTheSameFM1sFactoryDataDiffers() throws {
        var theirs = SampleFlash.flash()
        theirs[0xF_F020] = 0x01
        let plan = try FlashPlan.restoring(SampleFlash.backup(theirs), onto: SampleFlash.backup(SampleFlash.flash()))
        #expect(plan.warnings.contains { $0.contains("different from the backup's") })
        #expect(plan.sectors.contains(0xF_F000))
    }

    @Test func refusesChangesOutsideWhatAPlanMayTouch() throws {
        var target = SampleFlash.flash()
        target[0x5000] ^= 1
        #expect(throws: FlashPlanError.outsideAllowedRange(0x5000)) {
            try FlashPlan(
                purpose: .restore,
                original: SampleFlash.backup(SampleFlash.flash()),
                target: target,
                allowed: [0..<0x4000],
                notes: []
            )
        }
    }

    @Test func refusesAnotherModelsFlash() throws {
        let smk = SampleFlash.backup(SampleFlash.flash(bootloader: BootloaderImage.sample(board: "smk37").bytes))
        #expect(throws: FlashPlanError.notAnFM1) { try FlashPlan.installing(BootloaderImage.sample(), onto: smk) }
        let smkFirmware = SampleFlash.backup(SampleFlash.flash(code: Array("..SMK-37 Pro_016..".utf8)))
        #expect(throws: FlashPlanError.notAnFM1) {
            try FlashPlan.restoring(SampleFlash.backup(SampleFlash.flash()), onto: smkFirmware)
        }
    }

    @Test func goesByTheFlashChipWhenTheFlashDoesntSay() throws {
        let blank = SimulatedDownloadMode.sampleFlash()
        let fm1 = try FlashPlan.restoring(SampleFlash.backup(SampleFlash.flash()), onto: SampleFlash.backup(blank))
        #expect(fm1.warnings.contains { $0.contains("its flash chip is the FM-1's") })
        let other = FlashBackup(
            bytes: blank, uniqueID: nil, chipKey: 0x980F, flashID: 0xEB_6014, loaderVersion: "1.2", date: Date())
        #expect(throws: FlashPlanError.notAnFM1) {
            try FlashPlan.restoring(SampleFlash.backup(SampleFlash.flash()), onto: other)
        }
    }

    @Test func refusesADamagedBootloaderInAPackage() throws {
        var flash = SampleFlash.flash()
        flash[0xA0 + 40] ^= 1
        let package = try SampleFlash.package(flash)
        #expect(throws: FlashPlanError.noBootloader) {
            try FlashPlan.installingBootloader(from: package, onto: SampleFlash.backup(SampleFlash.flash()))
        }
    }

    @Test func refusesABootloaderTooLargeForTheBootArea() throws {
        let large = SampleFlash.stockBootloader(codeLength: 0x3900)
        #expect(throws: FlashPlanError.bootloaderTooLarge(large.count)) {
            try FlashPlan.installingBootloader(large, described: "large", onto: SampleFlash.backup(SampleFlash.flash()))
        }
    }

    @Test(arguments: [0x2000..<0x3000, 0x9_3000..<0x9_3800])
    func refusesSettingsThatCantBeErasedSafely(region: Range<Int>) throws {
        let package = try SampleFlash.package(SampleFlash.flash(regions: [("VM", region)]))
        #expect(throws: FlashPlanError.settingsOverFactoryData) {
            try FlashPlan.installing(package, onto: SampleFlash.backup(SampleFlash.flash()), erasingSettings: true)
        }
    }

    @Test func readsSavedBackupsWithAndWithoutTheirDescription() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "fm1rescue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bare = folder.appending(path: "bare.bin")
        try Data(SampleFlash.flash()).write(to: bare)
        let read = try FlashBackup(contentsOf: bare)
        #expect(read.uniqueID == nil)
        #expect(read.chipKey == 0x980F)
        let short = folder.appending(path: "short.bin")
        try Data(count: 1000).write(to: short)
        #expect(throws: DownloadModeError.unexpectedFlashSize(1000)) { try FlashBackup(contentsOf: short) }
        let unknown = SampleFlash.backup(SampleFlash.flash(), uniqueID: nil)
        let files = try unknown.write(to: folder)
        #expect(try FlashBackup(contentsOf: files.flash).uniqueID == nil)
    }
}
