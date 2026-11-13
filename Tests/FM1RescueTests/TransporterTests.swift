@_spi(Testing) import FM1Kit
import Testing

@testable import FM1Rescue

/// Working with an FM-1 through the FM-1 Transporter, against a simulated one.
struct TransporterTests {
    /// A stand-in for `wl82loader.bin`, which FM1Kit doesn't include.
    static let loader = (0..<24_064).map { UInt8(truncatingIfNeeded: $0 &* 7) }

    /// A Transporter in boot mode with m-bootloader's loader sent, and what its chip reports.
    static func ready(_ simulated: SimulatedTransporter) throws -> (Transporter, Transporter.Chip) {
        let transporter = Transporter(link: simulated)
        let status = try transporter.waitForBootMode(timeout: .seconds(5))
        try transporter.sendLoader(.mBootloader, status: status)
        return (transporter, try transporter.chip())
    }

    /// A plan to install a sample firmware over `original`, as the Transporter writes it.
    static func plan(onto original: [UInt8]) throws -> FlashPlan {
        let incoming = SampleFlash.flash(code: SampleFlash.code(fill: 0x77))
        return try FlashPlan.installingWithTransporter(
            try SampleFlash.package(incoming), onto: SampleFlash.backup(original, uniqueID: nil))
    }

    @Test func backsUpTheWholeFlashAndNamesItsLoader() throws {
        let flash = SampleFlash.flash()
        let (transporter, chip) = try Self.ready(SimulatedTransporter(flash: flash))
        #expect(chip == Transporter.Chip(key: 0x980F, flashID: FM1FlashChip.p25q80))
        let backup = try transporter.backUp(chip)
        #expect(backup.bytes == flash)
        #expect(backup.uniqueID == nil)
        #expect(backup.loaderVersion == "m-bootloader's flash loader 1.3, through the FM-1 Transporter")
    }

    @Test func waitsForTheFM1ToBeSwitchedOn() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        simulated.isWaitingForFM1 = true
        simulated.switchesOnAfter = 200
        let transporter = Transporter(link: simulated)
        transporter.switchedOffAfter = .milliseconds(20)
        var waited = 0
        let status = try transporter.waitForBootMode(timeout: .seconds(5)) { waited += 1 }
        #expect(waited == 1)
        #expect(status.isInBootMode)
    }

    @Test func givesUpWhenTheFM1IsNeverSwitchedOn() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        simulated.isWaitingForFM1 = true
        simulated.switchesOnAfter = .max
        let transporter = Transporter(link: simulated)
        transporter.switchedOffAfter = .milliseconds(20)
        #expect(throws: TransporterError.notInBootMode) {
            try transporter.waitForBootMode(timeout: .milliseconds(50))
        }
        #expect(try transporter.status() == nil)
    }

    @Test func asksARunningV15ToSwitchToBootMode() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        simulated.isRunningV15 = true
        let status = try Transporter(link: simulated).waitForBootMode(timeout: .seconds(5))
        #expect(status.isInBootMode)
        #expect(!simulated.isRunningV15)
    }

    @Test func refusesAnotherLoader() throws {
        let transporter = Transporter(link: SimulatedTransporter(flash: SampleFlash.flash()))
        let status = try transporter.waitForBootMode(timeout: .seconds(5))
        #expect(throws: TransporterError.wrongLoader(FwscPackage.sha256Hex(Self.loader))) {
            try transporter.sendLoader(.wl82loader(Self.loader), status: status)
        }
    }

    @Test func sendsWl82loaderWhereItIsBuiltToRun() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        let transporter = Transporter(link: simulated)
        transporter.acceptedLoaderSHA256 = FwscPackage.sha256Hex(Self.loader)
        let status = try transporter.waitForBootMode(timeout: .seconds(5))
        try transporter.sendLoader(.wl82loader(Self.loader), status: status)
        #expect(simulated.loaderAddress == 0x1C0_2000)
        let chip = try transporter.chip()
        #expect(chip.flashID == FM1FlashChip.p25q80)
        #expect(try transporter.backUp(chip).loaderVersion.hasPrefix("jl-uboot-tool's wl82loader"))
    }

    @Test func sendsMBootloadersLoaderScrambledWhereItIsBuiltToRun() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        _ = try Self.ready(simulated)
        #expect(simulated.loaderAddress == FlashLoaderImage.bundled[0].address)
    }

    @Test func saysWhenTheTransportersFirmwareTakesOnlyWl82loader() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        simulated.takesAnyLoader = false
        #expect(throws: TransporterError.loaderNotTaken) { try Self.ready(simulated) }
    }

    @Test func leavesARunningLoaderAlone() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        let (transporter, _) = try Self.ready(simulated)
        let status = try transporter.waitForBootMode(timeout: .seconds(5))
        #expect(status.isLoaderRunning)
        try transporter.sendLoader(.wl82loader([1, 2, 3]), status: status)
    }

    @Test func refusesAChipThatIsNotAnFM1s() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        simulated.flashID = 0xEB_6014
        #expect(throws: TransporterError.notAnFM1(chipKey: 0x980F, flashID: 0xEB_6014)) {
            try Self.ready(simulated)
        }
    }

    @Test func refusesAReadThatDoesNotMatchItsChecksum() throws {
        let simulated = SimulatedTransporter(flash: SampleFlash.flash())
        let (transporter, chip) = try Self.ready(simulated)
        simulated.corruptsNextRead = true
        #expect(throws: TransporterError.readsDiffer) { try transporter.backUp(chip) }
    }

    @Test func writesOnlyTheChangedSectorsFromTheTopDown() throws {
        let original = SampleFlash.flash()
        let simulated = SimulatedTransporter(flash: original)
        let (transporter, _) = try Self.ready(simulated)
        let plan = try Self.plan(onto: original)
        #expect(plan.sectors.count > 1)
        try transporter.write(plan)
        #expect(simulated.writtenSectors == plan.sectors.reversed())
        #expect(simulated.flash == plan.target)
    }

    @Test func saysToEraseWhatAnotherFirmwareLeftBehind() throws {
        let incoming = try SampleFlash.package(SampleFlash.flash(code: SampleFlash.code(fill: 0x77)))
        let same = try FlashPlan.installingWithTransporter(
            incoming, onto: SampleFlash.backup(SampleFlash.flash(), uniqueID: nil))
        #expect(same.afterwards.isEmpty)
        let other = Array("..FM-1_909..".utf8) + [UInt8](repeating: 0x5A, count: 0x3000 - 12)
        let replacing = try FlashPlan.installingWithTransporter(
            incoming, onto: SampleFlash.backup(SampleFlash.flash(code: other), uniqueID: nil))
        #expect(replacing.warnings.contains { $0.contains("saved data above 0x92FFF") })
        #expect(replacing.afterwards.contains { $0.contains("--erase-saved-data") })
    }

    @Test func writesNothingWhenTheFlashHasChanged() throws {
        let original = SampleFlash.flash()
        var changed = original
        changed[0x9_4000] ^= 0xFF
        let simulated = SimulatedTransporter(flash: changed)
        let (transporter, _) = try Self.ready(simulated)
        #expect(throws: TransporterError.flashChanged) { try transporter.write(try Self.plan(onto: original)) }
        #expect(simulated.writtenSectors.isEmpty)
    }

    @Test func writesNothingOutsideWhatTheTransporterWrites() throws {
        let original = SampleFlash.flash()
        var restored = original
        restored[0x9_3000] ^= 0xFF
        let simulated = SimulatedTransporter(flash: original)
        let (transporter, _) = try Self.ready(simulated)
        let plan = try FlashPlan.restoring(
            SampleFlash.backup(restored, uniqueID: nil), onto: SampleFlash.backup(original, uniqueID: nil))
        #expect(throws: TransporterError.outsideWritableRange(0x9_3000)) { try transporter.write(plan) }
        #expect(simulated.writtenSectors.isEmpty)
    }

    @Test func stopsAtASectorTheTransporterRefuses() throws {
        let original = SampleFlash.flash()
        let simulated = SimulatedTransporter(flash: original)
        let (transporter, _) = try Self.ready(simulated)
        let plan = try Self.plan(onto: original)
        simulated.failingSector = plan.sectors[0]
        #expect(throws: TransporterError.writeFailed(at: plan.sectors[0], "ERR write")) {
            try transporter.write(plan)
        }
        #expect(simulated.writtenSectors == plan.sectors.dropFirst().reversed())
    }

    @Test func readsTheTransportersStatus() throws {
        let status = try Transporter.status("OK uboot=1 v15=0 loader=1 loader_running=0")
        #expect(status == Transporter.Status(isInBootMode: true, isRunningV15: false, hasLoader: true))
        #expect(try Transporter.status("OK uboot=1 v15=0 loader=1 loader_running=1").isLoaderRunning)
        #expect(throws: TransporterError.refused("status", "ERR unknown")) { try Transporter.status("ERR unknown") }
    }
}
