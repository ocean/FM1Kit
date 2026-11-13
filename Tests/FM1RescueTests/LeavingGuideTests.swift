@_spi(Testing) import FM1Kit
import Foundation
import Testing

/// Working out, before installing a firmware, how to switch away from it.
struct LeavingGuideTests {
    /// A sample firmware whose code holds `markers`, as a real one's would.
    static func firmware(_ markers: String, product: String = "FM-1_916") throws -> FwscPackage {
        let code = Array("..\(product)..\(markers)..".utf8) + [UInt8](repeating: 0x5A, count: 0x3000)
        return try SampleFlash.package(SampleFlash.flash(code: code), product: product)
    }

    @Test func readsHowAFirmwareInstallsOthers() throws {
        #expect(try Self.firmware("FELUCCA-LOADER-1").updateCode == .feluccaOriginalCheck)
        #expect(try Self.firmware("FELUCCA-LOADER-1..AC79BLID").updateCode == .feluccaFixedCheck)
        #expect(try Self.firmware("FELUCCA-LOADER-1..LOADER NOT STAGED").updateCode == .ownLoader)
        #expect(try Self.firmware("BAUD").updateCode == .unknown)
        #expect(try Self.firmware("", product: "FM-1_015").updateCode == .mVave)
        let installer = try FwscPackage(data: FwscPackage.sampleBootloaderInstallerFile(carrying: .sample()))
        #expect(installer.updateCode == nil)
        #expect(LeavingGuide(package: installer, bootArea: .v15) == nil)
    }

    @Test func sendsPeopleThroughAFixedFirmwareFromTheOriginalCheckOnM_Bootloader() throws {
        let package = try Self.firmware("FELUCCA-LOADER-1")
        let guide = try #require(LeavingGuide(package: package, name: "Felucca 1.6.1", bootArea: .mBootloader))
        #expect(guide.bootArea == .mBootloader)
        #expect(guide.route(to: .v15) == .throughFixedFirmware)
        #expect(guide.route(to: .v16) == .throughFixedFirmware)
        #expect(guide.route(to: .mBootloader) == .throughFixedFirmware)
        #expect(guide.route(to: .feluccaPlatform) == .direct)
        #expect(guide.warnings.count == 1)
        #expect(guide.warnings.first?.contains("can't install V15 or V16 straight away") == true)
        #expect(
            guide.instructions(to: .v15) == [
                "Felucca 1.6.1 can't install V15 directly: its update check refuses it while the FM-1 has "
                    + "m-bootloader.",
                "Install MIDIMON 0.4 first: Felucca 1.6.1 can install it.",
                "Then install V15 from that.",
                "On a Mac, installing V15 in download mode works whatever firmware is running.",
            ])
    }

    @Test func letsTheOriginalCheckTakeOnlyTheBootloaderTheFM1Has() throws {
        let guide = try #require(LeavingGuide(package: try Self.firmware("FELUCCA-LOADER-1"), bootArea: .v15))
        #expect(guide.route(to: .v15) == .direct)
        #expect(guide.route(to: .v16) == .throughFixedFirmware)
        #expect(guide.route(to: .openFirmware) == .throughFixedFirmware)
        #expect(guide.instructions(to: .v16).first == "\(guide.firmwareName) can't install V16 directly.")
        let overV16 = try #require(LeavingGuide(package: try Self.firmware("FELUCCA-LOADER-1"), bootArea: .v16))
        #expect(overV16.route(to: .v15) == .throughFixedFirmware)
        #expect(overV16.route(to: .v16) == .uncertain)
        let unknown = try #require(LeavingGuide(package: try Self.firmware("FELUCCA-LOADER-1"), bootArea: nil))
        #expect(unknown.route(to: .v15) == .uncertain)
        #expect(unknown.warnings.isEmpty)
    }

    @Test func letsAFixedFirmwareGoAnywhere() throws {
        let package = try Self.firmware("FELUCCA-LOADER-1..AC79BLID")
        let guide = try #require(LeavingGuide(package: package, bootArea: .mBootloader))
        #expect(LeavingDestination.allCases.allSatisfy { guide.route(to: $0) == .direct })
        #expect(guide.warnings.isEmpty)
    }

    @Test func warnsThatTransitFM1ReportsV15sIdentityAndKeepsTheBootloader() throws {
        let package = try Self.firmware("FELUCCA-LOADER-1..LOADER NOT STAGED", product: "FM-1_015")
        let guide = try #require(LeavingGuide(package: package, name: "TransitFM1", bootArea: .v16))
        #expect(guide.route(to: .v15) == .direct)
        #expect(guide.route(to: .openFirmware) == .throughFixedFirmware)
        #expect(guide.route(to: .v16) == .throughFixedFirmware)
        #expect(guide.warnings.count == 2)
        #expect(guide.warnings.first?.contains("can't install V16 straight away") == true)
        #expect(guide.warnings.last?.hasPrefix("TransitFM1 reports itself as V15") == true)
        let steps = guide.instructions(to: .v15)
        #expect(steps.contains("TransitFM1 reports itself as V15: confirm it isn't really V15 when asked."))
        #expect(steps.contains { $0.contains("keeps the bootloader it has") })
        let toV16 = guide.instructions(to: .v16)
        #expect(
            toV16.first == "TransitFM1 can't install V16 directly: it only takes firmware images the size of V15's.")
        #expect(!toV16.contains { $0.contains("keeps the bootloader it has") || $0.contains("isn't really V15") })
    }

    @Test func keepsTheBootloaderWhenAFirmwareComesWithItsOwnLoader() throws {
        let package = try Self.firmware("FELUCCA-LOADER-1")
        #expect(LeavingGuide(package: package, bootArea: .v16, installedBy: .mVave)?.bootArea == .v16)
        let v15 = try Self.firmware("", product: "FM-1_015")
        #expect(LeavingGuide(package: v15, bootArea: .mBootloader)?.bootArea == .mBootloader)
    }

    @Test func letsV15InstallAnything() {
        let guide = LeavingGuide(firmwareName: "V15", identity: .officialV15, updateCode: .mVave, bootArea: .v15)
        #expect(LeavingDestination.allCases.allSatisfy { guide.route(to: $0) == .direct })
        let v16 = LeavingGuide(firmwareName: "V16", identity: .officialV16, updateCode: .mVave, bootArea: .v16)
        #expect(v16.route(to: .mBootloader) == .uncertain)
        #expect(v16.warnings.isEmpty)
    }

    @Test func canBeSavedWithTheFM1() throws {
        let identity = try #require(FM1Identity(text: "FM-1_916"))
        let guide = LeavingGuide(
            firmwareName: "Felucca 1.6.1",
            identity: identity,
            updateCode: .feluccaOriginalCheck,
            bootArea: .mBootloader
        )
        let saved = try JSONEncoder().encode(guide)
        #expect(try JSONDecoder().decode(LeavingGuide.self, from: saved) == guide)
    }
}
