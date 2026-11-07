@_spi(Testing) import FM1Kit
import Testing

/// Reading which flash chips a firmware checks for from its package.
struct FlashChipSupportTests {
    /// A firmware package whose code holds these 32-bit constants.
    static func package(holding constants: [UInt32]) throws -> FwscPackage {
        var code = SampleFlash.code()
        for (index, value) in constants.enumerated() {
            let start = 0x100 + 8 * index
            code.replaceSubrange(
                start..<(start + 4), with: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        return try SampleFlash.package(SampleFlash.flash(code: code))
    }

    @Test func readsWhichChipsTheCodeChecksFor() throws {
        #expect(try Self.package(holding: [0x85_6014, 0xB3_6014]).flashChipSupport == .bothChips)
        #expect(try Self.package(holding: [0x85_6014]).flashChipSupport == .firstChipOnly)
        #expect(try Self.package(holding: []).flashChipSupport == .noCheck)
    }

    @Test func saysNothingForAnInstaller() throws {
        let installer = try FwscPackage(data: FwscPackage.sampleBootloaderInstallerFile())
        #expect(installer.flashChipSupport == nil)
    }
}
