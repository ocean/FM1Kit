@_spi(Testing) import FM1Kit
import Testing

@testable import FM1Rescue

/// Comparing two flash backups, or two packages' images, part by part.
struct FlashComparisonTests {
    private func part(_ name: String, in comparison: FlashComparison) throws -> FlashComparison.Part {
        try #require(comparison.parts.first { $0.name == name })
    }

    @Test func findsNothingBetweenTheSameBackup() {
        let backup = SampleFlash.backup(SampleFlash.flash())
        let comparison = backup.compared(with: backup)
        #expect(comparison.isSame)
        #expect(
            comparison.parts.map(\.name) == [
                "boot area", "app table", "file app.bin", "region VM", "undeclared data", "factory data",
                "everything else",
            ])
    }

    @Test func pointsToTheSectorsSavedDataChangedIn() throws {
        let original = SampleFlash.flash()
        var changed = original
        changed[0x9_4010] = 0x00
        let comparison = SampleFlash.backup(original).compared(with: SampleFlash.backup(changed))
        let settings = try part("region VM", in: comparison)
        #expect(settings.outcome == .changed)
        #expect(settings.detail == "0x1000 bytes differ: 0x94000–0x94FFF")
        #expect(try part("file app.bin", in: comparison).outcome == .same)
        #expect(try part("everything else", in: comparison).outcome == .same)
    }

    @Test func comparesFilesDeciphered() throws {
        let comparison = SampleFlash.backup(SampleFlash.flash())
            .compared(with: SampleFlash.backup(SampleFlash.flash(code: SampleFlash.code(fill: 0x77))))
        let app = try part("file app.bin", in: comparison)
        #expect(app.outcome == .changed)
        #expect(app.detail.hasPrefix("CRC "))
        #expect(app.detail.hasSuffix("bytes differ"))
        #expect(try part("app table", in: comparison).detail == "changes app.bin")
    }

    @Test func notesRegionsDeclaredDifferently() throws {
        let first = SampleFlash.backup(SampleFlash.flash(regions: [("VM", 0x9_3000..<0x9_5000)]))
        let second = SampleFlash.backup(
            SampleFlash.flash(regions: [("VM", 0x9_4000..<0x9_6000), ("SEQ64", 0xA_0000..<0xA_2000)]))
        let comparison = first.compared(with: second)
        #expect(try part("region VM", in: comparison).detail == "declared at 0x93000–0x94FFF in the first")
        #expect(try part("region SEQ64", in: comparison).outcome == .added)
        #expect(try part("app table", in: comparison).detail == "adds SEQ64; changes VM")
    }

    @Test func findsChangesOutsideEveryPart() throws {
        let original = SampleFlash.flash()
        var changed = original
        changed[0x9_8123] ^= 0xFF
        changed[0xF_C123] ^= 0xFF
        let comparison = SampleFlash.backup(original).compared(with: SampleFlash.backup(changed))
        let rest = try part("everything else", in: comparison)
        #expect(rest.outcome == .changed)
        #expect(rest.detail == "0x1000 bytes differ: 0x98000–0x98FFF")
        #expect(try part("undeclared data", in: comparison).detail == "0x1000 bytes differ: 0xFC000–0xFCFFF")
        #expect(try part("factory data", in: comparison).outcome == .same)
    }

    @Test func comparesPackagesImages() throws {
        let first = try SampleFlash.package(SampleFlash.flash())
        let second = try SampleFlash.package(SampleFlash.flash(code: SampleFlash.code(fill: 0x77)))
        let comparison = try #require(first.compared(with: second))
        #expect(!comparison.isSame)
        #expect(try part("file app.bin", in: comparison).outcome == .changed)
        #expect(try part("region VM", in: comparison).detail == "declared alike")
        #expect(!comparison.parts.contains { $0.name == "factory data" })
        #expect(try #require(first.compared(with: first)).isSame)
    }
}
