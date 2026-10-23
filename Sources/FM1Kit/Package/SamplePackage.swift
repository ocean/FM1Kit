public import Foundation

// Sample packages for tests, here and in apps that use SimulatedFM1. A sample's parts are filler,
// so it must never be installed on a real FM-1.

@_spi(Testing)
extension FwscPackage {
    /// A part to put in a sample package's container.
    public struct SamplePart: Sendable {
        /// The part's type: ``flash(size:)`` and ``loader(size:)`` give the real ones.
        public var type: Int
        /// The part's name.
        public var name: String
        /// The part's length in bytes.
        public var size: Int
        /// The space the part takes up; its size when `nil`.
        public var storedSize: Int?
        /// Mark the part as enciphered, as the `USR` part holding V15's voices is: its checksum
        /// covers its deciphered bytes, and only the voice restore checks it.
        public var isEnciphered = false
        /// Where the part starts; straight after the previous part when `nil`.
        public var offset: Int?

        /// Makes a part.
        public init(type: Int, name: String, size: Int, storedSize: Int? = nil, isEnciphered: Bool = false) {
            self.type = type
            self.name = name
            self.size = size
            self.storedSize = storedSize
            self.isEnciphered = isEnciphered
        }

        /// A firmware image of this size, which must be whole 4 KB sectors.
        public static func flash(size: Int = 32_768) -> Self {
            Self(type: FirmwareContainer.flashType, name: "flash.bin", size: size)
        }

        /// An update loader of this size.
        public static func loader(size: Int = 1_000) -> Self {
            Self(type: FirmwareContainer.loaderType, name: "ota.bin", size: size)
        }
    }

    /// Where the first part starts, as in real packages.
    public static let firstPartOffset = 0x400

    /// Builds a small package file that passes every check, for tests with ``SimulatedFM1``.
    ///
    /// Its parts are a pattern, not firmware: never install it on a real FM-1. The firmware
    /// image's application area is `0x4400..<(0x400 + flashSize)`.
    ///
    /// - Parameters:
    ///   - product: The identity the package carries, e.g. `FM-1_916`.
    ///   - flashSize: The firmware image's size: whole 4 KB sectors, at least 16 KB.
    ///   - loaderSize: The update loader's size, under 32 KB.
    ///   - seed: Varies the pattern, so packages built with different seeds differ.
    /// - Returns: The `.fwsc` file's contents.
    public static func sampleFile(
        product: String,
        flashSize: Int = 32_768,
        loaderSize: Int = 1_000,
        seed: Int = 13
    ) -> Data {
        Data(
            sampleFile(
                logicalImage: sampleImage(parts: [.flash(size: flashSize), .loader(size: loaderSize)], seed: seed),
                product: product))
    }

    /// Builds a logical image holding a container of these parts, filled with a pattern.
    ///
    /// - Parameters:
    ///   - parts: The container's parts, in order.
    ///   - chip: The chip the container names.
    ///   - imageLength: The image's length; just after the last part when `nil`.
    ///   - seed: Varies the pattern.
    ///   - contents: Bytes for some parts in place of the pattern, by their index in `parts`.
    /// - Returns: The logical image, with a valid header and table.
    public static func sampleImage(
        parts: [SamplePart],
        chip: String = "AC791N",
        imageLength: Int? = nil,
        seed: Int = 13,
        contents: [Int: [UInt8]] = [:]
    ) -> [UInt8] {
        var offsets: [Int] = []
        var next = firstPartOffset
        for part in parts {
            let offset = part.offset ?? next
            offsets.append(offset)
            next = offset + (part.storedSize ?? part.size)
        }
        let length = imageLength ?? next
        var image = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* seed &+ 5) }
        for (index, bytes) in contents {
            image.replaceSubrange(offsets[index]..<(offsets[index] + bytes.count), with: bytes)
        }

        var table: [UInt8] = []
        for (part, offset) in zip(parts, offsets) {
            let stored = part.storedSize ?? part.size
            let end = min(offset + part.size, length)
            var fields = [UInt8](repeating: 0, count: FirmwareContainer.entryLength)
            put(part.type, into: &fields, at: 0, byteCount: 2)
            // An enciphered part's checksum covers its bytes deciphered as the `USR` part is.
            let plain = part.isEnciphered ? decipherUserData(image, range: offset..<end) : Array(image[offset..<end])
            let checksum = Int(FirmwareContainer.crc16(plain))
            put(checksum, into: &fields, at: 4, byteCount: 2)
            put(offset, into: &fields, at: 8, byteCount: 4)
            put(part.size, into: &fields, at: 12, byteCount: 4)
            put(stored, into: &fields, at: 16, byteCount: 4)
            put(part.isEnciphered ? stored : 0, into: &fields, at: 24, byteCount: 4)
            fields.replaceSubrange(64..<(64 + part.name.utf8.count), with: part.name.utf8)
            table += FirmwareContainer.decipher(fields)
        }

        var header = [UInt8](repeating: 0, count: FirmwareContainer.headerLength)
        put(Int(FirmwareContainer.crc16(table)), into: &header, at: 2, byteCount: 2)
        put(length, into: &header, at: 4, byteCount: 4)
        put(parts.count, into: &header, at: 8, byteCount: 2)
        header.replaceSubrange(16..<(16 + chip.utf8.count), with: chip.utf8)
        put(Int(FirmwareContainer.crc16(header[2...])), into: &header, at: 0, byteCount: 2)

        image.replaceSubrange(0..<header.count, with: FirmwareContainer.decipher(header))
        image.replaceSubrange(header.count..<(header.count + table.count), with: table)
        return image
    }

    /// Builds the file form of a logical image: the image with the identity markers added.
    ///
    /// - Parameters:
    ///   - logicalImage: At least the 20 header blocks' worth of image.
    ///   - product: The identity, up to 20 characters.
    /// - Returns: The `.fwsc` file's bytes.
    public static func sampleFile(logicalImage: [UInt8], product: String) -> [UInt8] {
        precondition(logicalImage.count >= blockCount * imageBytesPerBlock, "The image must fill the header blocks.")
        let productBytes = Array(product.utf8)
        precondition(productBytes.count <= blockCount, "The identity must fit in the header's markers.")
        var file: [UInt8] = []
        for block in 0..<blockCount {
            let start = block * imageBytesPerBlock
            file += logicalImage[start..<(start + imageBytesPerBlock)]
            file.append(
                block < productBytes.count
                    ? UInt8(truncatingIfNeeded: Int(productBytes[block]) + block + 1) : unusedMarker)
        }
        file += logicalImage[(blockCount * imageBytesPerBlock)...]
        return file
    }

    private static func put(_ value: Int, into bytes: inout [UInt8], at offset: Int, byteCount: Int) {
        for index in 0..<byteCount {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    }
}
