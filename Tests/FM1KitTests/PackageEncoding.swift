@testable import FM1Kit

/// A part to put in a test package's container.
struct TestPart {
    var type: Int
    var name: String
    var size: Int
    /// The space the part takes up; its size when `nil`.
    var storedSize: Int?
    var isEnciphered = false
    /// Where the part starts; straight after the previous part when `nil`.
    var offset: Int?

    static func flash(size: Int = 32_768) -> Self {
        Self(type: FirmwareContainer.flashType, name: "flash.bin", size: size)
    }

    static func loader(size: Int = 1_000) -> Self {
        Self(type: FirmwareContainer.loaderType, name: "ota.bin", size: size)
    }
}

extension FwscPackage {
    /// Where the first part starts, as in real packages.
    static let firstPartOffset = 0x400

    /// Builds a package file with a valid container (used by the tests).
    static func encode(
        product: String,
        flashSize: Int = 32_768,
        loaderSize: Int = 1_000,
        seed: Int = 13
    ) -> [UInt8] {
        encode(
            logicalImage: containerImage(parts: [.flash(size: flashSize), .loader(size: loaderSize)], seed: seed),
            product: product
        )
    }

    /// Builds a logical image holding a container of these parts, filled with a pattern.
    static func containerImage(
        parts: [TestPart],
        chip: String = FirmwareContainer.chip,
        imageLength: Int? = nil,
        seed: Int = 13
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

        var table: [UInt8] = []
        for (part, offset) in zip(parts, offsets) {
            let stored = part.storedSize ?? part.size
            let end = min(offset + part.size, length)
            var fields = [UInt8](repeating: 0, count: FirmwareContainer.entryLength)
            put(part.type, into: &fields, at: 0, byteCount: 2)
            let checksum = part.isEnciphered ? 0xBEEF : Int(FirmwareContainer.crc16(image[offset..<end]))
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

    /// Builds the file form of a logical image (used by the tests).
    static func encode(logicalImage: [UInt8], product: String) -> [UInt8] {
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
