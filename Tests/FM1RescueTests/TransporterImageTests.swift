@_spi(Testing) import FM1Kit
import Testing

@testable import FM1Rescue

/// Making the flash image the FM-1 Transporter writes.
struct TransporterImageTests {
    @Test func changesOnlyWhatTheTransporterWrites() throws {
        let incoming = SampleFlash.flash(code: SampleFlash.code(fill: 0x77))
        var original = SampleFlash.flash(bootloader: BootloaderImage.sample().bytes)
        original[0x9_3000] = 0x01
        let plan = try FlashPlan.installingWithTransporter(
            try SampleFlash.package(incoming), onto: SampleFlash.backup(original))
        #expect(!plan.isEmpty)
        #expect(plan.sectors.allSatisfy { FlashPlan.transporterWritable.contains($0) })
        #expect(plan.target[0x4000..<0x8000] == incoming[0x4000..<0x8000])
        #expect(plan.target[0..<0x4000] == original[0..<0x4000])
        #expect(plan.target[0x8000...] == original[0x8000...])
    }

    @Test func refusesFirmwareReachingPastWhatTheTransporterWrites() throws {
        var incoming = SampleFlash.flash()
        incoming[0x9_3000] = 0x02
        let package = try SampleFlash.package(incoming, size: 0x9_4000)
        #expect(throws: FlashPlanError.outsideTransporterRange(0x9_3000)) {
            try FlashPlan.installingWithTransporter(package, onto: SampleFlash.backup(SampleFlash.flash()))
        }
    }

    @Test func takesTheFlashIDTheTransporterShowedForABackupWithoutOne() throws {
        let unnamed = [UInt8](repeating: 0x5A, count: 0x3000)
        let dump = SampleFlash.backup(SampleFlash.flash(code: unnamed), uniqueID: nil, flashID: 0)
        let package = try SampleFlash.package(SampleFlash.flash(code: SampleFlash.code(fill: 0x77)))
        #expect(throws: FlashPlanError.notAnFM1) {
            try FlashPlan.installingWithTransporter(package, onto: dump)
        }
        let plan = try FlashPlan.installingWithTransporter(package, onto: dump, flashID: 0x85_6014)
        #expect(!plan.isEmpty)
        #expect(plan.warnings.count == 1)
    }
}
