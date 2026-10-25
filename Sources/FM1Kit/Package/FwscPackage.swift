import CryptoKit
public import Foundation

/// A `.fwsc` firmware package as distributed for the FM-1 (official and custom firmwares alike).
///
/// The first 20 blocks of 0x30 bytes each carry 0x2F image bytes plus one marker byte. The
/// markers spell the product identity (`FM-1_916`): marker `i` is `character + i + 1`, and
/// `0x7D` means "unused". The image the device reads during an update (the logical image) is
/// the file with those 20 marker bytes removed.
///
/// The logical image is a JieLi firmware container: a header and table of parts, each with a
/// checksum. Reading a package checks all of them, and that it holds a firmware image and an
/// update loader for the FM-1's AC791N chip, so a damaged or wrong file is refused before
/// anything is sent to the device. A package holding only an update loader brings an installer
/// rather than firmware (``isFirmware`` is false), as m-bootloader's do.
public struct FwscPackage: Sendable {
    /// Why a file couldn't be read as an FM-1 package.
    public enum Failure: Error, Hashable, LocalizedError {
        /// The file is too short to hold the package header.
        case tooShort
        /// The file is larger than any FM-1 package.
        case tooLarge
        /// The header's markers don't spell an identity such as `FM-1_916`; this is what they spell.
        case unreadableProduct(String)
        /// The package is for another model; this is the model it names.
        case unexpectedModel(String)
        /// The container's header or table of parts is damaged.
        case damagedHeader
        /// The package is for another chip; this is the chip it names.
        case unexpectedChip(String)
        /// A part of the package doesn't match its checksum; this is the part's name.
        case damagedPart(String)
        /// The package has no usable firmware image or update loader; this says which.
        case missingPart(String)

        /// A description suitable for showing to the person who chose the file.
        public var errorDescription: String? {
            switch self {
            case .tooShort:
                "This file is too short to be an FM-1 firmware package."
            case .tooLarge:
                "This file is too large to be an FM-1 firmware package."
            case .unreadableProduct(let text):
                "This file doesn't carry an FM-1 product identity (it reads \"\(text)\")."
            case .unexpectedModel(let model):
                "This package is for a \(model), not an FM-1."
            case .damagedHeader:
                "This package's header is damaged, so it can't be installed. Download it again."
            case .unexpectedChip(let chip):
                "This package is for a \(chip) chip, not the FM-1's AC791N."
            case .damagedPart(let name):
                "Part of this package (\(name)) is damaged, so it can't be installed. Download it again."
            case .missingPart(let part):
                "This package has no usable \(part), so it can't be installed."
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
    /// The largest file accepted, well beyond the FM-1's 1 MB of flash plus extras.
    static let maximumFileLength = 2_097_152

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

    /// Lower-case hex SHA-256 of the update loader the package brings.
    ///
    /// The loader reports its own identity while it writes, which isn't always the package's:
    /// M-VAVE's loader, ``OfficialFirmware/stockLoaderSHA256``, always reports `ota-FM-1_015`.
    public let loaderSHA256: String

    /// The parts of the logical image.
    let container: FirmwareContainer

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
        guard bytes.count <= Self.maximumFileLength else {
            throw .tooLarge
        }
        let product = Self.decodeProduct(bytes)
        guard let identity = FM1Identity(text: product), product.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else {
            throw .unreadableProduct(product)
        }
        guard identity.model == Self.expectedModel else {
            throw .unexpectedModel(identity.model)
        }
        let image = Self.stripMarkers(bytes)
        container = try FirmwareContainer(image: image)
        fileBytes = bytes
        self.identity = identity
        logicalImage = image
        sha256 = Self.sha256Hex(bytes)
        loaderSHA256 = Self.sha256Hex(image[container.loader.range])
    }

    /// The identity as text, e.g. `FM-1_916`.
    public var product: String { identity.text }

    /// True when the package brings a firmware to install; false for one that only brings an
    /// installer, such as m-bootloader's (see ``BootloaderInstaller``).
    ///
    /// ``FM1Updater/install(_:options:events:)`` installs only firmware.
    public var isFirmware: Bool { container.flash != nil }

    /// The firmware image as it's stored in flash from address 0: the boot area, then the
    /// application, enciphered with the chip key the package was made for; `nil` for an
    /// installer package.
    package var flashImage: [UInt8]? {
        container.flash.map { Array(logicalImage[$0.range]) }
    }

    /// Where the firmware image's boot area (its first 16 KB) is in the logical image, which
    /// update requests address; `nil` for an installer package.
    var bootAreaRange: Range<Int>? {
        container.flash.map { $0.range.lowerBound..<min($0.range.lowerBound + 0x4000, $0.range.upperBound) }
    }

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
/// (<https://www.m-vave.com/download>), or V15 from M-VAVE's open-source repository
/// (<https://github.com/m-vave/fm1_open>, Apache-2.0), and check them here.
public struct OfficialFirmware: Sendable, Hashable {
    /// A display name, e.g. "FM-1 V15".
    public let name: String
    /// The file size in bytes.
    public let size: Int
    /// Lower-case hex SHA-256 of the file.
    public let sha256: String
    /// The build ID open firmware is armed with to install it; see ``FM1Capability``.
    public let buildID: FM1BuildID

    /// FM-1 V15 `FM-1.fwsc`, as pinned by the Felucca and firmware hub installers.
    ///
    /// Its build ID is its SHA-256, as in M-VAVE's updater.
    public static let v15 = Self(
        name: "FM-1 V15",
        size: 699_956,
        sha256: "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a",
        buildID: FM1BuildID(knownHex: "db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a")
    )

    /// M-VAVE's open firmware V12 (`FM-1_8000012`).
    ///
    /// The package embedded in M-VAVE's `FM1-Open-V12-Workbench.html` release, which M-VAVE marks
    /// as not yet validated on hardware.
    public static let openV12 = Self(
        name: "FM1 Open V12",
        size: 475_700,
        sha256: "2dd4f2d2f020851f8797752371704a9a541aa747f4e20419d629de9aa2c66f43",
        buildID: FM1BuildID(knownHex: "426b7fa5cf1626bceaa05e8106b9a8b0eaad7f49d8b2c157303f15be347596aa")
    )

    /// Lower-case hex SHA-256 of M-VAVE's update loader, which V15 and M-VAVE's open-source
    /// firmware both bring; see ``FwscPackage/loaderSHA256``.
    public static let stockLoaderSHA256 = "ef1f2db89b011fa53e71df363f0122de0ea896618c53fb53e8da676322004541"

    /// Every release FM1Kit recognises.
    public static let known: [Self] = [.v15, .openV12]

    /// Recognises an official release.
    ///
    /// - Parameter package: A package read from a file.
    /// - Returns: The official release the package is byte for byte, or `nil` for any other package.
    public static func matching(_ package: FwscPackage) -> Self? {
        known.first { $0.size == package.fileBytes.count && $0.sha256 == package.sha256 }
    }
}
