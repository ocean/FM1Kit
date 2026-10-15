@testable import FM1Kit

extension FwscPackage {
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
}
