#if os(macOS)
/// The chip's download-mode commands, and those of the flash loader that runs on it.
///
/// The chip's ROM (`UBOOT1.00`) takes memory writes and a jump; FM1Kit writes m-bootloader's
/// flash loader into RAM and starts it, and the loader then answers flash commands, an on-chip
/// CRC-32 and the flash's unique ID. Each command is 16 bytes: a big-endian opcode, big-endian
/// arguments, then `FF` padding. The layout follows m-bootloader's specification (§10) and
/// M-Flasher's `jl.rs` (MIT, Julius Vitkauskas), which follows jl-uboot-tool (MIT, Andrey
/// Grigoryev).
enum ChipCommand {
    /// The ROM's memory write: address, length and CRC-16 of the (scrambled) block, then the block.
    static let writeMemory: UInt16 = 0xFB06
    /// The ROM's jump: address, then the loader's target, 1 for SPI NOR flash.
    static let jump: UInt16 = 0xFB08
    /// Reads flash: address and length, then the raw bytes.
    static let readFlash: UInt16 = 0xFD05
    /// The chip's encryption key, scrambled.
    static let readKey: UInt16 = 0xFC09
    /// The flash chip's JEDEC ID; JieLi's loader answers it too.
    static let onlineDevice: UInt16 = 0xFC0A
    /// m-bootloader's loader: `MFLR`, its version, address, features and clock.
    static let identify: UInt16 = 0xFC40
    /// m-bootloader's loader: IEEE CRC-32 of part of the flash, computed on the chip.
    static let crc32: UInt16 = 0xFC41
    /// m-bootloader's loader: the flash chip's 8-byte unique ID.
    static let uniqueID: UInt16 = 0xFC42

    /// The loader's target argument for SPI NOR flash.
    static let norFlashTarget: UInt16 = 1
    /// The argument ``readKey`` is sent with.
    static let keyMagic: UInt32 = 0x00AC_6900
    /// A standard SCSI INQUIRY for 36 bytes.
    static let inquiry: [UInt8] = [0x12, 0, 0, 0, 36, 0]

    /// A 16-byte command block.
    static func block(_ opcode: UInt16, _ arguments: [UInt8] = []) -> [UInt8] {
        var block = [UInt8](repeating: 0xFF, count: 16)
        block[0] = UInt8(opcode >> 8)
        block[1] = UInt8(opcode & 0xFF)
        block.replaceSubrange(2..<(2 + arguments.count), with: arguments)
        return block
    }

    /// A big-endian integer.
    static func bigEndian(_ value: UInt32, byteCount: Int) -> [UInt8] {
        (0..<byteCount).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// Reads a big-endian integer.
    static func readBigEndian(_ bytes: [UInt8], at offset: Int, byteCount: Int) -> UInt32 {
        (0..<byteCount).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[offset + $1]) }
    }

    /// The arguments of a memory write: address, length, a zero, then the block's CRC-16
    /// (little-endian, unlike everything else).
    static func memoryWriteArguments(address: UInt32, block: [UInt8]) -> [UInt8] {
        let crc = ChipChecksum.crc16(block)
        return bigEndian(address, byteCount: 4) + bigEndian(UInt32(block.count), byteCount: 2) + [0]
            + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }
}

/// The checksums and scrambling download mode uses.
enum ChipChecksum {
    /// The CRC-16 of the chip's tools (polynomial 0x1021), continuing from `start`.
    static func crc16(_ bytes: some Sequence<UInt8>, from start: UInt16 = 0) -> UInt16 {
        var value = start
        for byte in bytes {
            value ^= UInt16(byte) << 8
            for _ in 0..<8 {
                value = value & 0x8000 == 0 ? value << 1 : (value << 1) ^ 0x1021
            }
        }
        return value
    }

    /// The standard CRC-32 (as in zlib), which m-bootloader's loader computes on the chip.
    static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return ~value
    }

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    /// The phrase JieLi's scrambling steps through.
    private static let phrase: [UInt8] = [
        0xC3, 0xCF, 0xC0, 0xE8, 0xCE, 0xD2, 0xB0, 0xAE, 0xC4, 0xE3, 0xA3, 0xAC, 0xD3, 0xF1, 0xC1, 0xD6,
    ]

    /// JieLi's scrambling ("CrcDecode"), its own inverse.
    ///
    /// Each byte is XORed with a CRC-16 that steps through a fixed phrase. Uploaded loader blocks
    /// and the chip key travel this way.
    static func scramble(_ bytes: some Sequence<UInt8>, key: UInt32 = 0xFFFF_FFFF) -> [UInt8] {
        var value = crc16([UInt8((key >> 16) & 0xFF), UInt8(key >> 24)], from: UInt16(key & 0xFFFF))
        return bytes.enumerated().map { index, byte in
            value = crc16([phrase[index % phrase.count]], from: value)
            return byte ^ UInt8(value & 0xFF)
        }
    }
}
#endif
