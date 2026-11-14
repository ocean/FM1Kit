public import Foundation

/// A firmware's resource region, as fm1-base firmwares keep it in flash: data the firmware reads
/// in place but doesn't need to start, such as LOOM-8's or WOODSHED's samples.
///
/// The region starts with a 32-byte header: the magic `RES1`, the payload's length and CRC-32,
/// and the header's own CRC-32 in its last 4 bytes. The payload follows. A firmware uses the
/// region only when the header and payload check and match its build, and the header is written
/// last, so a region cut short is ignored rather than misread.
///
/// It comes two ways: as a `NAME-res.bin` file published beside the package, which the
/// firmware takes over USB-MIDI once it's running (``FM1Updater/writeResources(_:progress:)``),
/// or inside the package as a part of type 101 that also names the region's flash address, which
/// the update loader writes after the firmware. Melodee's packages carry a part of type 101 too,
/// in its own format, which this doesn't read.
public struct ResourceRegion: Sendable, Hashable {
    /// Why bytes aren't a resource region.
    public enum Failure: Error, Hashable, LocalizedError {
        /// The bytes are too short to hold the header.
        case tooShort
        /// The header isn't a resource header, or its checksum doesn't match.
        case notResources
        /// The payload is cut short or doesn't match its CRC-32.
        case damaged

        /// A description suitable for showing to the person who chose the file.
        public var errorDescription: String? {
            switch self {
            case .tooShort:
                "This file is too short to be a firmware's resources."
            case .notResources:
                "This file isn't a firmware's resources (a NAME-res.bin from fm1-base's build)."
            case .damaged:
                "These resources are cut short or damaged. Download them again."
            }
        }
    }

    /// The header's length.
    public static let headerLength = 32
    /// The header's magic, `RES1`.
    static let magic: UInt32 = 0x3153_4552
    /// Where firmwares keep resource regions: whole sectors from `0x97000` up to `0xE0000`.
    public static let dataArea = 0x9_7000..<0xE_0000

    /// The region as the flash holds it: header, payload and any padding after it.
    public let bytes: [UInt8]
    /// The payload's length.
    public let payloadLength: Int
    /// The payload's CRC-32, which the firmware checks against its build.
    public let payloadCRC: UInt32
    /// Where the region goes in flash, when a package names it; `nil` for a separate file.
    public let address: Int?

    /// The payload, after the header.
    public var payload: ArraySlice<UInt8> { bytes[Self.headerLength..<(Self.headerLength + payloadLength)] }

    /// The flash the region takes, padded to whole sectors, when its address is known.
    public var flashRange: Range<Int>? {
        address.map { $0..<($0 + (bytes.count + 0xFFF) / 0x1000 * 0x1000) }
    }

    /// Reads and checks a region.
    ///
    /// - Parameters:
    ///   - bytes: A `NAME-res.bin` file, or a package's part of type 101.
    ///   - address: Where the region goes in flash, from the package's part.
    /// - Throws: ``Failure`` when the bytes aren't a whole, undamaged region.
    public init(bytes: [UInt8], address: Int? = nil) throws(Failure) {
        guard bytes.count >= Self.headerLength else { throw .tooShort }
        guard Self.hasHeader(bytes) else { throw .notResources }
        let length = Int(Self.integer(bytes, at: 4))
        let crc = Self.integer(bytes, at: 8)
        guard length <= bytes.count - Self.headerLength,
            Self.crc32(bytes[Self.headerLength..<(Self.headerLength + length)]) == crc
        else {
            throw .damaged
        }
        self.bytes = bytes
        payloadLength = length
        payloadCRC = crc
        self.address = address
    }

    /// True when the bytes start with a resource header whose checksum matches, whatever the
    /// payload holds.
    public static func hasHeader(_ bytes: some Collection<UInt8>) -> Bool {
        let header = Array(bytes.prefix(headerLength))
        return header.count == headerLength && integer(header, at: 0) == magic
            && integer(header, at: 28) == crc32(header[0..<28])
    }

    /// The standard CRC-32 (as in zlib).
    package static func crc32(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return ~value
    }

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private static func integer(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}

extension FwscPackage {
    /// The resource region the package carries in fm1-base's form, with the flash address its part
    /// names, or `nil`.
    ///
    /// It's `nil` for a package without one, and for a part FM1Kit can't place itself: Melodee's,
    /// which names no address, or one whose address isn't whole sectors of
    /// ``ResourceRegion/dataArea`` clear of the firmware image. The update loader still writes
    /// those; see ``carriesOtherResources``.
    public var resources: ResourceRegion? {
        guard let entry = container.resources, entry.flashAddress != 0,
            entry.flashAddress.isMultiple(of: FirmwareContainer.flashSectorSize),
            entry.flashAddress >= (container.flash?.size ?? 0),
            let region = try? ResourceRegion(bytes: Array(logicalImage[entry.range]), address: entry.flashAddress),
            let range = region.flashRange, range.upperBound <= ResourceRegion.dataArea.upperBound,
            ResourceRegion.dataArea.contains(range.lowerBound)
        else {
            return nil
        }
        return region
    }

    /// True when the package carries a resource region that only its update loader can write,
    /// such as Melodee's, so installing it in download mode leaves the region out.
    public var carriesOtherResources: Bool {
        container.resources != nil && resources == nil
    }
}

@_spi(Testing)
extension ResourceRegion {
    /// Builds a sample resource region: a header and a patterned payload, padded with `0xFF` to
    /// whole 4 KB sectors, as fm1-base's build makes `NAME-res.bin` for a package.
    ///
    /// - Parameters:
    ///   - payloadLength: The payload's length.
    ///   - seed: Varies the pattern, so regions built with different seeds differ.
    /// - Returns: The region's bytes.
    public static func sampleBytes(payloadLength: Int, seed: Int = 11) -> [UInt8] {
        let payload = (0..<payloadLength).map { UInt8(truncatingIfNeeded: $0 &* seed &+ 3) }
        var header = [UInt8](repeating: 0, count: headerLength)
        for (offset, value) in [(0, magic), (4, UInt32(payloadLength)), (8, crc32(payload))] {
            header.replaceSubrange(offset..<(offset + 4), with: FM1Message.littleEndian(value, byteCount: 4))
        }
        header.replaceSubrange(28..<32, with: FM1Message.littleEndian(crc32(header[0..<28]), byteCount: 4))
        let region = header + payload
        return region + [UInt8](repeating: 0xFF, count: (0x1000 - region.count % 0x1000) % 0x1000)
    }
}
