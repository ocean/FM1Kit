@_spi(Testing) import FM1Kit
import Foundation
import Testing

/// Checking a firmware package before release.
struct ReleaseCheckTests {
    /// The outcomes found about `topic`.
    static func outcomes(_ report: PackageCheck, _ topic: PackageCheck.Topic) -> [PackageCheck.Outcome] {
        report.findings.filter { $0.topic == topic }.map(\.outcome)
    }

    /// Saved data laid out as V15's.
    static let v15Regions = [("VM", 0x9_3000..<0xE_9000), ("BTIF", 0xE_9000..<0xE_A000), ("USR", 0xE_A000..<0xF_C000)]

    @Test func passesASoundPackage() throws {
        let report = PackageCheck(try SampleFlash.package(SampleFlash.flash(regions: Self.v15Regions)))
        #expect(report.passes)
        #expect(Self.outcomes(report, .chipKey) == [.pass])
        #expect(Self.outcomes(report, .flashChips) == [.pass])
        #expect(Self.outcomes(report, .savedData) == [.pass])
        #expect(Self.outcomes(report, .recovery) == [.pass])
        // The sample's loader is neither M-VAVE's nor Felucca's, so Felucca's original check refuses it.
        #expect(Self.outcomes(report, .installing) == [.pass, .warning])
    }

    @Test func warnsWhenTheCodeKnowsOnlyTheFirstFlashChip() throws {
        let code = SampleFlash.code() + [0x14, 0x60, 0x85, 0x00]
        let report = PackageCheck(try SampleFlash.package(SampleFlash.flash(code: code)))
        #expect(Self.outcomes(report, .flashChips) == [.warning])
        #expect(report.passes)
    }

    @Test func failsSavedDataThatIsntWholeSectors() throws {
        let flash = SampleFlash.flash(regions: [("VM", 0x9_3000..<0x9_3800)])
        let report = PackageCheck(try SampleFlash.package(flash))
        #expect(Self.outcomes(report, .savedData) == [.failure])
        #expect(!report.passes)
    }

    @Test func failsSavedDataReachingWhereEveryFirmwareKeepsData() throws {
        let flash = SampleFlash.flash(regions: [("USR", 0xE_A000..<0xF_D000)])
        let report = PackageCheck(try SampleFlash.package(flash))
        #expect(Self.outcomes(report, .savedData) == [.failure])
    }

    @Test func failsSavedDataOverTheImageAndNotesWhatTheTransporterCantWrite() throws {
        let flash = SampleFlash.flash(regions: [("VM", 0x9_3000..<0x9_5000)])
        let report = PackageCheck(try SampleFlash.package(flash, size: 0x9_4000))
        #expect(Self.outcomes(report, .savedData) == [.failure])
        #expect(Self.outcomes(report, .recovery) == [.note])
    }

    @Test func notesSavedDataSharingV15sSpaceDifferently() throws {
        let flash = SampleFlash.flash(regions: [("VM", 0x9_3000..<0x9_5000)])
        let report = PackageCheck(try SampleFlash.package(flash))
        #expect(Self.outcomes(report, .savedData) == [.pass, .note])
    }

    @Test func failsAnImageNotEncipheredForTheFM1sChipKey() throws {
        let report = PackageCheck(try FwscPackage(data: FwscPackage.sampleFile(product: "FM-1_378001")))
        #expect(Self.outcomes(report, .chipKey) == [.failure])
        #expect(report.worst == .failure)
    }

    @Test func warnsWhenAFirmwareReportsM_VAVEsIdentity() throws {
        let report = PackageCheck(try SampleFlash.package(SampleFlash.flash(), product: "FM-1_015"))
        #expect(Self.outcomes(report, .identity) == [.warning])
    }

    @Test func notesThatAnInstallerHoldsNoFirmware() throws {
        let image = FwscPackage.sampleImage(parts: [.loader()])
        let package = try FwscPackage(data: Data(FwscPackage.sampleFile(logicalImage: image, product: "FM-1_378001")))
        let report = PackageCheck(package)
        #expect(report.findings.map(\.outcome) == [.note])
    }
}
