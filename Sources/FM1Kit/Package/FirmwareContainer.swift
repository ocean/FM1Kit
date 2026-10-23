import Foundation

/// The JieLi firmware container inside a package's logical image, checked part by part.
///
/// The container starts with a 64-byte header and a table of 80-byte entries, each enciphered
/// with ``decipher(_:)``. The header carries checksums of itself and of the table, the image's
/// length and the chip model; each entry names a part (the firmware image `flash.bin`, the update
/// loader `ota.bin`, and vendor extras) with its offset, size and checksum. The format follows
/// kagaimiq's MIT-licensed jl-misctools, as used by M-VAVE's own package builder.
struct FirmwareContainer {
    /// One part of the container.
    struct Entry: Equatable {
        /// The part's type: 0 for the firmware image, 100 for the update loader.
        let type: Int
        /// The part's name, such as `flash.bin`.
        let name: String
        /// Where the part starts in the logical image.
        let offset: Int
        /// The part's length in bytes.
        let size: Int
        /// The space the part takes up in the image, which can be padded beyond its size.
        let storedSize: Int
        /// How many bytes are stored enciphered: none, or the whole stored size.
        let encipheredLength: Int
        /// The part's checksum.
        let checksum: UInt16

        /// Reads an entry from its deciphered fields.
        init(fields: [UInt8]) {
            type = FirmwareContainer.integer(fields, at: 0, byteCount: 2)
            name = FirmwareContainer.text(fields[64...])
            offset = FirmwareContainer.integer(fields, at: 8, byteCount: 4)
            size = FirmwareContainer.integer(fields, at: 12, byteCount: 4)
            storedSize = FirmwareContainer.integer(fields, at: 16, byteCount: 4)
            encipheredLength = FirmwareContainer.integer(fields, at: 24, byteCount: 4)
            checksum = UInt16(FirmwareContainer.integer(fields, at: 4, byteCount: 2))
        }

        /// True when the part is stored enciphered, so its checksum can't be checked here.
        var isEnciphered: Bool { encipheredLength != 0 }

        /// The part's bytes in the logical image.
        var range: Range<Int> { offset..<(offset + size) }

        /// The space the part takes up, cut off at the end of an image this long.
        func stored(within imageLength: Int) -> Range<Int> {
            (offset..<(offset + storedSize)).clamped(to: 0..<imageLength)
        }
    }

    static let headerLength = 64
    static let entryLength = 80
    static let maximumEntries = 12
    static let chip = "AC791N"
    static let flashType = 0
    static let loaderType = 100
    static let userDataType = 50
    static let userDataName = "USR"
    /// The firmware image's valid sizes: whole 4 KB flash sectors, up to the chip's flash.
    static let flashSizes = 16_384...1_044_480
    static let flashSectorSize = 4096
    /// The update loader's valid sizes.
    static let loaderSizes = 1..<32_768
    /// The boot area at the start of the firmware image, before the application.
    static let bootAreaLength = 0x4000

    /// The firmware image the loader writes to flash, or `nil` for a package that only brings an
    /// installer, such as m-bootloader's.
    let flash: Entry?
    /// The update loader that writes it.
    let loader: Entry
    /// M-VAVE's user data part (`USR`), which holds V15's factory voices, if the package has one.
    let userData: Entry?

    /// Reads and checks the container in a package's logical image.
    ///
    /// - Parameter image: The logical image, with the identity markers removed.
    /// - Throws: ``FwscPackage/Failure`` when the header, table or a part is damaged, the chip
    ///   isn't the FM-1's, the update loader is missing, or a firmware image is missing alongside
    ///   other parts. A package holding only an update loader is an installer, with no firmware.
    init(image: [UInt8]) throws(FwscPackage.Failure) {
        guard image.count >= Self.headerLength else { throw .damagedHeader }
        let header = Self.decipher(image[0..<Self.headerLength])
        let count = Self.integer(header, at: 8, byteCount: 2)
        guard
            Self.integer(header, at: 0, byteCount: 2) == Int(Self.crc16(header[2...])),
            Self.integer(header, at: 4, byteCount: 4) == image.count
        else {
            throw .damagedHeader
        }
        let chip = Self.text(header[16..<32])
        guard chip == Self.chip else { throw .unexpectedChip(chip) }

        let tableEnd = Self.headerLength + count * Self.entryLength
        guard
            (1...Self.maximumEntries).contains(count),
            tableEnd <= image.count,
            Self.integer(header, at: 2, byteCount: 2) == Int(Self.crc16(image[Self.headerLength..<tableEnd]))
        else {
            throw .damagedHeader
        }

        var entries: [Entry] = []
        for index in 0..<count {
            let start = Self.headerLength + index * Self.entryLength
            let entry = Entry(fields: Self.decipher(image[start..<(start + Self.entryLength)]))
            // Padding may run past the end of the image (Felucca 1.6.1's loader does), but the part may not.
            let stored = entry.stored(within: image.count)
            guard
                entry.offset >= tableEnd, entry.storedSize >= entry.size, entry.range.upperBound <= image.count,
                !entry.isEnciphered || entry.encipheredLength == entry.storedSize,
                !entries.contains(where: { stored.overlaps($0.stored(within: image.count)) })
            else {
                throw .damagedHeader
            }
            guard entry.isEnciphered || Self.crc16(image[entry.range]) == entry.checksum else {
                throw .damagedPart(entry.name)
            }
            entries.append(entry)
        }

        let flashes = entries.filter { $0.type == Self.flashType }
        let loaders = entries.filter { $0.type == Self.loaderType }
        // A package of nothing but its loader brings an installer, which the bootloader runs.
        let isInstaller = flashes.isEmpty && entries.count == 1 && loaders.count == 1
        let flash = flashes.first
        guard
            isInstaller
                || (flashes.count == 1 && flash.map { !$0.isEnciphered && Self.isFlashSize($0.size) } == true)
        else {
            throw .missingPart("firmware image")
        }
        guard loaders.count == 1, let loader = loaders.first, !loader.isEnciphered,
            Self.loaderSizes.contains(loader.size)
        else {
            throw .missingPart("update loader")
        }
        self.flash = flash
        self.loader = loader
        userData = entries.first { $0.type == Self.userDataType && $0.name == Self.userDataName }
    }

    /// The firmware image's application area, after its boot area.
    ///
    /// Every loader seen so far writes this area; some also rewrite the boot area first. An
    /// image no bigger than the boot area counts as all application.
    /// An installer package has no firmware image, so its range is empty.
    var applicationRange: Range<Int> {
        guard let flash else { return 0..<0 }
        return flash.size > Self.bootAreaLength
            ? (flash.offset + Self.bootAreaLength)..<flash.range.upperBound : flash.range
    }

    /// True for a firmware image's size: whole 4 KB flash sectors, up to the chip's flash.
    static func isFlashSize(_ size: Int) -> Bool {
        flashSizes.contains(size) && size.isMultiple(of: flashSectorSize)
    }

    /// The CRC-16 the container uses (polynomial 0x1021, starting from 0).
    static func crc16(_ bytes: some Collection<UInt8>) -> UInt16 {
        var value: UInt16 = 0
        for byte in bytes {
            value ^= UInt16(byte) << 8
            for _ in 0..<8 {
                value = value & 0x8000 == 0 ? value << 1 : (value << 1) ^ 0x1021
            }
        }
        return value
    }

    /// Deciphers (or enciphers: it's symmetric) a header or table entry, or a block of an
    /// enciphered part.
    ///
    /// Each byte is XORed with the low byte of a 16-bit key that starts at `key` (0xFFFF for the
    /// header and table) and steps like the CRC-16 register.
    static func decipher(_ bytes: some Collection<UInt8>, key start: UInt16 = 0xFFFF) -> [UInt8] {
        var key = start
        return bytes.map { byte in
            defer { key = key & 0x8000 == 0 ? key << 1 : (key << 1) ^ 0x1021 }
            return byte ^ UInt8(truncatingIfNeeded: key)
        }
    }

    static func integer(_ bytes: [UInt8], at offset: Int, byteCount: Int) -> Int {
        (0..<byteCount).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }

    static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }
}
