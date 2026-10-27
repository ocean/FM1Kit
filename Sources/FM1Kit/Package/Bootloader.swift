public import Foundation

/// A bootloader for the FM-1's chip, as an m-bootloader release's `.boot` file holds it: a
/// single-bank JieLi boot container, checked and identified.
///
/// m-bootloader (<https://github.com/jvitkauskas/m-bootloader>, MIT) replaces the bootloader
/// M-VAVE ships. It adds a recovery menu (hold PLAY while switching on) and the chip's USB
/// download mode (hold REC), and starts firmware only once its checksums pass. Its containers
/// carry the marker `AC79BLID`, the board they're built for and their version; the layout
/// follows m-bootloader's specification (§4.1, §11.1).
public struct BootloaderImage: Sendable, Hashable {
    /// The container: a 16-byte header, then the code the chip runs.
    public let bytes: [UInt8]
    /// The board it's built for: `fm1` for the FM-1.
    public let board: String
    /// The version it reports, such as `1.2-22e2559`.
    public let version: String

    /// The board name of FM-1 builds.
    public static let fm1Board = "fm1"
    /// The header's length.
    static let headerLength = 16
    /// Where the chip loads and starts the code.
    static let loadAddress: UInt32 = 0x01C0_2000
    /// The largest container that fits the FM-1's boot area.
    static let maximumLength = 0x3830
    /// The marker m-bootloader puts in its code, 0x40 bytes in.
    static let marker = Array("AC79BLID".utf8)
    static let markerOffset = 0x40
    static let boardOffset = 0x48
    static let versionOffset = 0x50
    static let versionLength = 32

    /// Checks a container and reads its board and version.
    ///
    /// Fails unless it's a single-bank container loaded at `0x01C02000` whose checksums match,
    /// which fits the boot area and carries m-bootloader's marker.
    ///
    /// - Parameter bytes: A `.boot` file's contents, or a container found elsewhere.
    public init?(bytes: some Collection<UInt8>) {
        let bytes = Array(bytes)
        let header = Self.headerLength
        guard bytes.count > header + Self.versionOffset, bytes.count <= Self.maximumLength else { return nil }
        let codeLength = Int(FM1Message.readLittleEndian(bytes, at: 2, byteCount: 2))
        guard
            FM1Message.readLittleEndian(bytes, at: 0, byteCount: 2) == 1,
            FM1Message.readLittleEndian(bytes, at: 4, byteCount: 4) == Self.loadAddress,
            FM1Message.readLittleEndian(bytes, at: 8, byteCount: 4) == UInt32(header),
            header + codeLength == bytes.count,
            FM1Message.readLittleEndian(bytes, at: 12, byteCount: 2)
                == UInt32(FirmwareContainer.crc16(bytes[header...])),
            FM1Message.readLittleEndian(bytes, at: 14, byteCount: 2) == UInt32(FirmwareContainer.crc16(bytes[0..<14])),
            bytes[(header + Self.markerOffset)...].starts(with: Self.marker)
        else {
            return nil
        }
        let board = FirmwareContainer.text(bytes[(header + Self.boardOffset)..<(header + Self.versionOffset)])
        let versionStart = header + Self.versionOffset
        let version = FirmwareContainer.text(bytes[versionStart..<min(versionStart + Self.versionLength, bytes.count)])
        guard !board.isEmpty, !version.isEmpty else { return nil }
        self.bytes = bytes
        self.board = board
        self.version = version
    }

    /// Reads a `.boot` file.
    ///
    /// - Parameter data: The file's contents.
    public init?(data: Data) {
        self.init(bytes: [UInt8](data))
    }

    /// Lower-case hex SHA-256 of the container, as m-bootloader's `SHA256SUMS` lists it.
    public var sha256: String { FwscPackage.sha256Hex(bytes) }
}

/// An m-bootloader installer package, such as `fm1-uboot.fwsc`: a `.fwsc` package that installs
/// m-bootloader over USB-MIDI instead of installing firmware.
///
/// The package holds no firmware, only an installer in place of the update loader. The running
/// firmware stages it like any update and restarts; the bootloader then runs the installer,
/// which rewrites only the 16 KB boot area, checks it, shows the result on the FM-1's screen and
/// restarts into the same firmware. ``FM1Updater/installBootloader(_:fromAnyFirmware:events:)`` drives that.
///
/// Reading one decompresses the installer and checks every checksum on the way, as the
/// bootloader does before running it, and finds the bootloader it installs.
public struct BootloaderInstaller: Sendable {
    /// Why a package isn't an m-bootloader installer for the FM-1.
    public enum Failure: Error, Hashable, LocalizedError {
        /// The package brings firmware, not an installer.
        case notAnInstaller
        /// The installer is damaged: a checksum or length doesn't match.
        case damaged
        /// The installer doesn't carry an m-bootloader the FM1Kit recognises.
        case noBootloader
        /// The bootloader is built for another board; this is the board it names.
        case otherBoard(String)

        /// A description suitable for showing to the person who chose the file.
        public var errorDescription: String? {
            switch self {
            case .notAnInstaller: "This package is a firmware, not a bootloader installer."
            case .damaged: "This bootloader installer is damaged, so it can't be used. Download it again."
            case .noBootloader: "This package doesn't install m-bootloader."
            case .otherBoard(let board): "This bootloader is built for \(board), not the FM-1."
            }
        }
    }

    /// The package as read from its file.
    public let package: FwscPackage
    /// The bootloader the installer writes.
    public let bootloader: BootloaderImage

    /// Checks a package and finds the bootloader its installer writes.
    ///
    /// - Parameter package: A package read from an m-bootloader release's `.fwsc` file.
    /// - Throws: ``Failure`` when it isn't an FM-1 m-bootloader installer, or is damaged.
    public init(package: FwscPackage) throws(Failure) {
        guard !package.isFirmware else { throw .notAnInstaller }
        let stream = package.logicalImage[package.container.loader.range]
        guard let code = StagedUpdater.decode(stream) else { throw .damaged }
        guard let bootloader = Self.findBootloader(in: code) else { throw .noBootloader }
        guard bootloader.board == BootloaderImage.fm1Board else { throw .otherBoard(bootloader.board) }
        self.package = package
        self.bootloader = bootloader
    }

    /// The first valid container in the installer's code, found by its marker.
    static func findBootloader(in code: [UInt8]) -> BootloaderImage? {
        let marker = BootloaderImage.marker
        let markerStart = BootloaderImage.headerLength + BootloaderImage.markerOffset
        var index = markerStart
        while index + marker.count <= code.count {
            if code[index..<(index + marker.count)].elementsEqual(marker) {
                let start = index - markerStart
                let codeLength = Int(FM1Message.readLittleEndian(code, at: start + 2, byteCount: 2))
                let end = start + BootloaderImage.headerLength + codeLength
                if end <= code.count, let image = BootloaderImage(bytes: code[start..<end]) {
                    return image
                }
            }
            index += 1
        }
        return nil
    }
}

/// A staged updater as a package's `ota.bin` carries it: a file record, a compression header,
/// then LZ4 blocks, decoded as m-bootloader's specification describes (§6.3).
enum StagedUpdater {
    /// Where every known updater, M-VAVE's and m-bootloader's installer alike, runs from.
    static let loadAddress: UInt32 = 0x01C0_A800
    /// The largest updater, M-VAVE's stock one.
    static let maximumLength = 0x5B1C
    /// The largest compressed block.
    static let maximumBlockLength = 4096
    /// The record and compression header before the blocks.
    static let headerLength = 64

    /// Decodes an updater, checking the record, the header, every block and the result.
    ///
    /// - Parameter stream: The `ota.bin` part.
    /// - Returns: The updater's code, or `nil` when anything doesn't check out.
    static func decode(_ stream: ArraySlice<UInt8>) -> [UInt8]? {
        let stream = Array(stream)
        guard stream.count > headerLength else { return nil }
        let record = stream[0..<32]
        let header = stream[32..<64]
        guard
            FM1Message.readLittleEndian(stream, at: 0, byteCount: 2)
                == UInt32(FirmwareContainer.crc16(record.dropFirst(2))),
            FM1Message.readLittleEndian(stream, at: 32, byteCount: 2)
                == UInt32(FirmwareContainer.crc16(header.dropFirst(2))),
            FM1Message.readLittleEndian(stream, at: 40, byteCount: 4) == loadAddress
        else {
            return nil
        }
        let length = Int(FM1Message.readLittleEndian(stream, at: 36, byteCount: 4))
        guard (1...maximumLength).contains(length) else { return nil }

        var output: [UInt8] = []
        output.reserveCapacity(length)
        var offset = headerLength
        while offset < stream.count {
            guard offset + 8 <= stream.count else { return nil }
            let packed = Int(FM1Message.readLittleEndian(stream, at: offset, byteCount: 4))
            let produced = Int(FM1Message.readLittleEndian(stream, at: offset + 4, byteCount: 4))
            offset += 8
            guard
                (1...maximumBlockLength).contains(packed), offset + packed <= stream.count,
                produced > 0, output.count + produced <= length,
                LZ4.decodeBlock(stream[offset..<(offset + packed)], producing: produced, after: &output)
            else {
                return nil
            }
            offset += packed
        }
        guard
            output.count == length,
            FM1Message.readLittleEndian(stream, at: 34, byteCount: 2) == UInt32(FirmwareContainer.crc16(output))
        else {
            return nil
        }
        return output
    }
}

/// LZ4 block decoding, with matches that may reach back into earlier blocks' output.
enum LZ4 {
    /// Decodes one block onto the end of `output`.
    ///
    /// - Returns: False when the block is malformed, reaches outside what's been produced, or
    ///   doesn't produce exactly `count` bytes.
    static func decodeBlock(_ block: ArraySlice<UInt8>, producing count: Int, after output: inout [UInt8]) -> Bool {
        let block = Array(block)
        let target = output.count + count
        var index = 0
        while index < block.count {
            let token = block[index]
            index += 1
            guard let literals = length(Int(token >> 4), in: block, at: &index),
                index + literals <= block.count, output.count + literals <= target
            else {
                return false
            }
            output += block[index..<(index + literals)]
            index += literals
            // The last sequence is literals only.
            if index == block.count { break }
            guard index + 2 <= block.count else { return false }
            let distance = Int(block[index]) | Int(block[index + 1]) << 8
            index += 2
            guard
                distance > 0, distance <= output.count,
                let extra = length(Int(token & 0x0F), in: block, at: &index)
            else {
                return false
            }
            let matchLength = extra + 4
            guard output.count + matchLength <= target else { return false }
            // Byte by byte, so a match may overlap what it's producing.
            for _ in 0..<matchLength {
                output.append(output[output.count - distance])
            }
        }
        return output.count == target
    }

    /// A literal or match length: the token's nibble, extended by bytes while they're 255.
    private static func length(_ nibble: Int, in block: [UInt8], at index: inout Int) -> Int? {
        guard nibble == 15 else { return nibble }
        var total = nibble
        while true {
            guard index < block.count else { return nil }
            let byte = block[index]
            index += 1
            total += Int(byte)
            if byte != 255 { return total }
        }
    }
}
