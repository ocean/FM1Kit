@_spi(Testing) import FM1Kit
import Foundation

@testable import FM1Rescue

/// Flash laid out as a real FM-1's is, for tests: a boot area with its file table and a
/// bootloader, and an app area enciphered with the chip key.
enum SampleFlash {
    static let chipKey: UInt16 = 0x980F
    /// Where the boot configuration starts, after the bootloader.
    static let configuration = 0x38D0

    /// 1 MB of flash holding a bootloader, `app.bin` and declared regions.
    static func flash(
        bootloader: [UInt8] = stockBootloader(),
        code: [UInt8] = Self.code(),
        regions: [(name: String, range: Range<Int>)] = [("VM", 0x9_3000..<0x9_5000)]
    ) -> [UInt8] {
        var flash = SimulatedDownloadMode.sampleFlash()
        flash.replaceSubrange(0..<0x4000, with: bootArea(holding: bootloader))
        let app = applicationArea(code: code, regions: regions)
        flash.replaceSubrange(0x4000..<(0x4000 + app.count), with: app)
        return flash
    }

    /// Firmware code that names itself, as real firmware does, filled out with `fill`.
    static func code(fill: UInt8 = 0x5A) -> [UInt8] {
        Array("..FM-1_378001..".utf8) + [UInt8](repeating: fill, count: 0x3000 - 15)
    }

    /// A bootloader container without m-bootloader's marker, standing in for M-VAVE's.
    static func stockBootloader(codeLength: Int = 600) -> [UInt8] {
        let code = (0..<codeLength).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 7) }
        var header = littleEndian(1, 2) + littleEndian(code.count, 2) + littleEndian(0x01C0_2000, 4)
        header += littleEndian(16, 4) + littleEndian(Int(ChipChecksum.crc16(code)), 2)
        header += littleEndian(Int(ChipChecksum.crc16(header)), 2)
        return header + code
    }

    /// The boot area as stored: a flash header, the file table, the bootloader and the unit's
    /// configuration.
    static func bootArea(holding container: [UInt8]) -> [UInt8] {
        var area = [UInt8](repeating: 0xFF, count: 0x4000)
        var header = (0..<32).map { UInt8(truncatingIfNeeded: $0 &* 3) }
        sign(&header)
        area.replaceSubrange(0..<32, with: FlashBackup.decipher(header[...]))
        let records = [
            record("uboot.boot", address: 0xA0, length: container.count, crc: ChipChecksum.crc16(container)),
            record("isd_config.ini", address: configuration, length: 0x100, crc: 0x1234),
            record("app_dir_head", address: 0x4000, length: 0x20, crc: 0x5678),
        ]
        for (index, fields) in records.enumerated() {
            let start = 0x20 + 32 * index
            area.replaceSubrange(start..<(start + 32), with: FlashBackup.decipher(fields[...]))
        }
        let stored = FlashBackup.decipher(container[0..<16]) + FlashBackup.decipher(container[16...])
        area.replaceSubrange(0xA0..<(0xA0 + stored.count), with: stored)
        area.replaceSubrange(configuration..<(configuration + 0x100), with: (0..<0x100).map { UInt8($0) })
        return area
    }

    /// The app area as stored: `app.bin` and the region descriptors, enciphered in 32-byte blocks.
    static func applicationArea(code: [UInt8], regions: [(name: String, range: Range<Int>)]) -> [UInt8] {
        let codeAddress = 0x200
        var area = [UInt8](repeating: 0xFF, count: codeAddress + code.count)
        var entries = [
            record("app.bin", address: codeAddress, length: code.count, crc: ChipChecksum.crc16(code), attribute: 0x82)
        ]
        entries += regions.map { region in
            record(region.name, address: region.range.lowerBound, length: region.range.count, crc: 0, attribute: 0x12)
        }
        for (index, entry) in entries.enumerated() {
            area.replaceSubrange((32 * index)..<(32 * index + 32), with: entry)
        }
        area.replaceSubrange(codeAddress..<area.count, with: code)
        area += [UInt8](repeating: 0xFF, count: (32 - area.count % 32) % 32)
        var stored: [UInt8] = []
        for block in stride(from: 0, to: area.count, by: 32) {
            let key = chipKey ^ UInt16(truncatingIfNeeded: block >> 2)
            stored += FlashBackup.decipher(area[block..<(block + 32)], key: key)
        }
        return stored
    }

    /// A firmware package whose image is this flash's first `size` bytes.
    static func package(_ flash: [UInt8], size: Int = 0x8000, product: String = "FM-1_378001") throws -> FwscPackage {
        let image = FwscPackage.sampleImage(
            parts: [.flash(size: size), .loader()], contents: [0: Array(flash[0..<size])])
        return try FwscPackage(data: Data(FwscPackage.sampleFile(logicalImage: image, product: product)))
    }

    static func backup(_ flash: [UInt8], uniqueID: String? = "53494d554c415445") -> FlashBackup {
        FlashBackup(
            bytes: flash,
            uniqueID: uniqueID,
            chipKey: chipKey,
            flashID: 0x85_6014,
            loaderVersion: "1.2",
            date: Date()
        )
    }

    /// A 32-byte table record, signed with its checksum.
    static func record(_ name: String, address: Int, length: Int, crc: UInt16, attribute: UInt8 = 0) -> [UInt8] {
        var fields = [UInt8](repeating: 0, count: 32)
        fields.replaceSubrange(2..<4, with: littleEndian(Int(crc), 2))
        fields.replaceSubrange(4..<8, with: littleEndian(address, 4))
        fields.replaceSubrange(8..<12, with: littleEndian(length, 4))
        fields[12] = attribute
        fields.replaceSubrange(16..<(16 + name.utf8.count), with: Array(name.utf8))
        sign(&fields)
        return fields
    }

    static func sign(_ fields: inout [UInt8]) {
        fields.replaceSubrange(0..<2, with: littleEndian(Int(ChipChecksum.crc16(fields[2...])), 2))
    }

    static func littleEndian(_ value: Int, _ byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
