import CryptoKit
public import Foundation

/// A `.fwsc` firmware package as distributed for the FM-1 (official and custom firmwares alike).
///
/// The first 20 blocks of 0x30 bytes each carry 0x2F image bytes plus one marker byte. The
/// markers spell the product identity (`FM-1_916`): marker `i` is `character + i + 1`, and
/// `0x7D` means "unused". The image the device reads during an update (the logical image) is
/// the file with those 20 marker bytes removed.
public struct FwscPackage: Sendable {
    /// Why a file couldn't be read as an FM-1 package.
    public enum Failure: Error, Hashable, LocalizedError {
        /// The file is too short to hold the package header.
        case tooShort
        /// The header's markers don't spell an identity such as `FM-1_916`; this is what they spell.
        case unreadableProduct(String)
        /// The package is for another model; this is the model it names.
        case unexpectedModel(String)

        /// A description suitable for showing to the person who chose the file.
        public var errorDescription: String? {
            switch self {
            case .tooShort:
                "This file is too short to be an FM-1 firmware package."
            case .unreadableProduct(let text):
                "This file doesn't carry an FM-1 product identity (it reads \"\(text)\")."
            case .unexpectedModel(let model):
                "This package is for a \(model), not an FM-1."
            }
        }
    }

    /// Header blocks that carry a marker byte.
    static let blockCount = 20
    /// Bytes in each header block, marker included.
    static let blockSize = 0x30
    /// Image bytes in each header block.
    static let imageBytesPerBlock = 0x2F
    /// The marker for a block that carries no identity character.
    static let unusedMarker: UInt8 = 0x7D

    /// The hardware model every FM-1 package is built for.
    public static let expectedModel = "FM-1"

    /// The file exactly as downloaded or imported.
    public let fileBytes: [UInt8]

    /// The identity the device should report once this package is installed.
    public let identity: FM1Identity

    /// The bytes the device reads, addressed from zero.
    public let logicalImage: [UInt8]

    /// Lower-case hex SHA-256 of the file (not the logical image).
    public let sha256: String

    /// Reads a package from a file's contents.
    ///
    /// - Parameter data: The `.fwsc` file's contents.
    /// - Throws: ``Failure`` when the file isn't an FM-1 package.
    public init(data: Data) throws(Failure) {
        try self.init(bytes: [UInt8](data))
    }

    /// Reads a package from a file's bytes.
    ///
    /// - Parameter bytes: The `.fwsc` file's bytes.
    /// - Throws: ``Failure`` when the file isn't an FM-1 package.
    public init(bytes: [UInt8]) throws(Failure) {
        guard bytes.count > Self.blockCount * Self.blockSize else {
            throw .tooShort
        }
        let product = Self.decodeProduct(bytes)
        guard let identity = FM1Identity(text: product), product.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw .unreadableProduct(product)
        }
        guard identity.model == Self.expectedModel else {
            throw .unexpectedModel(identity.model)
        }
        fileBytes = bytes
        self.identity = identity
        logicalImage = Self.stripMarkers(bytes)
        sha256 = Self.sha256Hex(bytes)
    }

    /// The identity as text, e.g. `FM-1_916`.
    public var product: String { identity.text }

    /// The identity the header's markers spell; `bytes` must hold the whole header.
    static func decodeProduct(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        for block in 0..<blockCount {
            let marker = bytes[block * blockSize + imageBytesPerBlock]
            if marker != unusedMarker {
                scalars.append(Unicode.Scalar(UInt8(truncatingIfNeeded: Int(marker) - block - 1)))
            }
        }
        return String(scalars)
    }

    /// The logical image: the file with the header's marker bytes removed.
    static func stripMarkers(_ bytes: [UInt8]) -> [UInt8] {
        var image: [UInt8] = []
        image.reserveCapacity(bytes.count - blockCount)
        for block in 0..<blockCount {
            let start = block * blockSize
            image += bytes[start..<(start + imageBytesPerBlock)]
        }
        image += bytes[(blockCount * blockSize)...]
        return image
    }

    /// Computes a SHA-256 checksum in the form publishers usually print.
    ///
    /// - Parameter bytes: The bytes to hash, such as a downloaded file.
    /// - Returns: The checksum as 64 lower-case hex digits.
    public static func sha256Hex(_ bytes: some DataProtocol) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

/// Official M-VAVE firmware releases, recognised by size and SHA-256.
///
/// FM1Kit doesn't include these files: get them from M-VAVE's downloads
/// (<https://www.m-vave.com/download>) and check them here.
public struct OfficialFirmware: Sendable, Hashable {
    /// A display name, e.g. "FM-1 V15".
    public let name: String
    /// The file size in bytes.
    public let size: Int
    /// Lower-case hex SHA-256 of the file.
    public let sha256: String

    /// FM-1 V15 `FM-1.fwsc`, as pinned by the Felucca and firmware hub installers.
    public static let v15 = Self(
        name: "FM-1 V15",
        size: 699_956,
        sha256: "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a"
    )

    /// Every release FM1Kit recognises.
    public static let known: [Self] = [.v15]

    /// Recognises an official release.
    ///
    /// - Parameter package: A package read from a file.
    /// - Returns: The official release the package is byte for byte, or `nil` for any other package.
    public static func matching(_ package: FwscPackage) -> Self? {
        known.first { $0.size == package.fileBytes.count && $0.sha256 == package.sha256 }
    }
}
