#if os(macOS)
import Foundation

/// An FM-1 in download mode, with m-bootloader's flash loader running on its chip, ready to read
/// its flash.
///
/// Opening one checks the device is the chip's ROM (`WL82 UBOOT1.00`), uploads the flash loader
/// into RAM unless the same version is already running, and reads the chip's key, the flash
/// chip's ID and its unique ID. Nothing is written to the flash until ``write(_:progress:)``.
/// The FM-1 stays in download mode until it's switched off and on.
///
/// Every call blocks until the device answers, so call it off the main thread.
public final class FlashSession {
    /// The flash loader's version, such as `1.2`.
    public let loaderVersion: String
    /// The CPU clock the loader runs the chip at, in MHz, or 0 if it doesn't say.
    public let clockMHz: Int
    /// The chip's encryption key; M-VAVE's FM-1s use `0x980F`.
    public let chipKey: UInt16
    /// The flash chip's JEDEC ID, such as `0x856014`.
    public let flashID: UInt32
    /// The flash chip's factory-unique ID as 16 hex digits, which tells one FM-1 from another;
    /// `nil` if the chip has none.
    public let uniqueID: String?

    /// The FM-1's flash size.
    public static let flashSize = 0x10_0000
    /// The FM-1's flash chip's JEDEC ID; the SMK-37's differs.
    static let fm1FlashID: UInt32 = 0x85_6014
    /// The chip key M-VAVE's FM-1s use.
    public static let expectedChipKey: UInt16 = 0x980F

    let connection: any DownloadModeConnection
    /// Bytes per read command.
    static let readLength = 16_384
    /// Times a failed transfer is tried in all.
    static let attempts = 4

    /// Starts the flash loader on a device in download mode.
    ///
    /// - Parameter connection: An open connection, such as ``USBDownloadModeConnection/open()``.
    /// - Throws: ``DownloadModeError`` when the device isn't the chip's ROM, another loader is
    ///   running, the loader doesn't start, or the flash isn't the FM-1's 1 MB.
    public init(connection: any DownloadModeConnection) throws(DownloadModeError) {
        self.connection = connection
        let answer = try connection.execute(ChipCommand.inquiry, .receive(36))
        let vendor = Self.text(answer, 8..<16)
        let product = Self.text(answer, 16..<32)
        guard vendor == "WL82", product == "UBOOT1.00" else {
            throw .notDownloadMode("\(vendor) \(product)")
        }

        let bundled = FlashLoaderImage.bundled
        var running = try? Self.identify(connection)
        if running == nil, (try? Self.call(connection, ChipCommand.onlineDevice)) != nil {
            // Another tool's loader answers flash commands but not ours; jumping through it isn't safe.
            throw .otherLoaderRunning
        }
        if running?.version != bundled.first?.version {
            // Upload to the address the running loader (if any) isn't using.
            let slot = bundled.first { $0.address != running?.address } ?? bundled[0]
            try Self.upload(slot, to: connection)
            running = try? Self.identify(connection)
            guard running?.version == slot.version else { throw .loaderDidNotStart }
        }
        loaderVersion = running?.version ?? ""
        clockMHz = running?.clockMHz ?? 0

        let key = try Self.call(
            connection, ChipCommand.readKey, ChipCommand.bigEndian(ChipCommand.keyMagic, byteCount: 4))
        let plainKey = ChipChecksum.scramble([key[7], key[6]])
        chipKey = UInt16(plainKey[0]) | UInt16(plainKey[1]) << 8
        let device = try Self.call(connection, ChipCommand.onlineDevice)
        flashID = UInt32(device[4]) | UInt32(device[5]) << 8 | UInt32(device[6]) << 16
        let capacity = 1 << Int(min(flashID & 0xFF, 40))
        guard capacity == Self.flashSize else { throw .unexpectedFlashSize(capacity) }
        let unique = try? Self.call(connection, ChipCommand.uniqueID)
        uniqueID = unique.flatMap { reply in
            let id = reply[2..<10]
            guard id.contains(where: { $0 != 0xFF }), id.contains(where: { $0 != 0 }) else { return nil }
            return id.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Reads part of the flash.
    ///
    /// - Parameters:
    ///   - range: The bytes to read.
    ///   - progress: Called with the bytes read so far.
    /// - Returns: The bytes, exactly as stored.
    /// - Throws: ``DownloadModeError`` when a read fails four times.
    public func read(_ range: Range<Int>, progress: (Int) -> Void = { _ in }) throws(DownloadModeError) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(range.count)
        while bytes.count < range.count {
            let length = min(Self.readLength, range.count - bytes.count)
            let address = UInt32(range.lowerBound + bytes.count)
            let command = ChipCommand.block(
                ChipCommand.readFlash,
                ChipCommand.bigEndian(address, byteCount: 4) + ChipCommand.bigEndian(UInt32(length), byteCount: 2))
            let part = try Self.retrying { () throws(DownloadModeError) in
                let part = try connection.execute(command, .receive(length))
                guard part.count == length else {
                    throw DownloadModeError.transferFailed(
                        "\(part.count) of \(length) bytes at 0x\(String(address, radix: 16))")
                }
                return part
            }
            bytes += part
            progress(bytes.count)
        }
        return bytes
    }

    /// The IEEE CRC-32 of part of the flash, computed by the loader on the chip.
    ///
    /// - Parameter range: The bytes to check.
    /// - Returns: The checksum.
    /// - Throws: ``DownloadModeError`` when the loader doesn't answer.
    public func crc32(of range: Range<Int>) throws(DownloadModeError) -> UInt32 {
        let arguments =
            ChipCommand.bigEndian(UInt32(range.lowerBound), byteCount: 4)
            + ChipCommand.bigEndian(UInt32(range.count), byteCount: 4)
        let reply = try Self.call(connection, ChipCommand.crc32, arguments)
        return ChipCommand.readBigEndian(reply, at: 2, byteCount: 4)
    }

    /// Lets go of the device; it stays in download mode until it's switched off.
    public func close() {
        connection.close()
    }

    // MARK: - Commands.

    /// What a running m-bootloader loader reports.
    struct RunningLoader {
        var version: String
        var address: UInt32
        var clockMHz: Int
    }

    /// Asks which of m-bootloader's loaders is running.
    static func identify(_ connection: any DownloadModeConnection) throws(DownloadModeError) -> RunningLoader? {
        let reply = try call(connection, ChipCommand.identify)
        guard reply[2..<6].elementsEqual("MFLR".utf8) else { return nil }
        return RunningLoader(
            version: text(reply, 6..<9),
            address: ChipCommand.readBigEndian(reply, at: 10, byteCount: 4),
            clockMHz: Int(reply[15])
        )
    }

    /// Uploads a loader in 512-byte scrambled blocks, then jumps to it.
    static func upload(_ loader: FlashLoaderImage, to connection: any DownloadModeConnection)
        throws(DownloadModeError)
    {
        for start in stride(from: 0, to: loader.bytes.count, by: 512) {
            let block = ChipChecksum.scramble(loader.bytes[start..<min(start + 512, loader.bytes.count)])
            let address = loader.address + UInt32(start)
            let command = ChipCommand.block(
                ChipCommand.writeMemory, ChipCommand.memoryWriteArguments(address: address, block: block))
            _ = try connection.execute(command, .send(block))
        }
        let arguments =
            ChipCommand.bigEndian(loader.address, byteCount: 4)
            + ChipCommand.bigEndian(UInt32(ChipCommand.norFlashTarget), byteCount: 2)
        _ = try call(connection, ChipCommand.jump, arguments)
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Sends a command that answers 16 bytes starting with its opcode, trying again if the
    /// transfer fails.
    static func call(_ connection: any DownloadModeConnection, _ opcode: UInt16, _ arguments: [UInt8] = [])
        throws(DownloadModeError) -> [UInt8]
    {
        let command = ChipCommand.block(opcode, arguments)
        return try retrying { () throws(DownloadModeError) in
            let reply = try connection.execute(command, .receive(16))
            guard reply.count == 16, ChipCommand.readBigEndian(reply, at: 0, byteCount: 2) == UInt32(opcode) else {
                throw DownloadModeError.transferFailed("an unexpected answer to 0x\(String(opcode, radix: 16))")
            }
            return reply
        }
    }

    /// Runs `body` until it succeeds, trying a failed transfer again after a pause; a command the
    /// device refused isn't tried again.
    static func retrying<Result>(_ body: () throws(DownloadModeError) -> Result) throws(DownloadModeError) -> Result {
        var attempt = 1
        while true {
            do {
                return try body()
            } catch .transferFailed where attempt < attempts {
                Thread.sleep(forTimeInterval: 0.25 * Double(attempt))
                attempt += 1
            }
        }
    }

    /// Trimmed ASCII text from part of a reply.
    static func text(_ bytes: [UInt8], _ range: Range<Int>) -> String {
        let slice = bytes[range.clamped(to: 0..<bytes.count)].prefix { $0 != 0 }
        return (String(bytes: slice, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
    }
}

/// One of m-bootloader's flash loader builds, as bundled with FM1Rescue.
struct FlashLoaderImage {
    /// Where it's built to run.
    let address: UInt32
    /// The loader.
    let bytes: [UInt8]
    /// Its version, from the `MFLR` marker in it.
    let version: String

    /// The two builds, at `0x01C20000` and `0x01C28000`, so a new one never overwrites one
    /// that's running.
    static let bundled: [Self] = [
        load("mflr-loader-a", address: 0x01C2_0000),
        load("mflr-loader-b", address: 0x01C2_8000),
    ].compactMap(\.self)

    private static func load(_ name: String, address: UInt32) -> Self? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "bin"),
            let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        let bytes = [UInt8](data)
        let marker = Array("MFLR".utf8)
        guard let start = (0...(bytes.count - 7)).first(where: { bytes[$0..<($0 + 4)].elementsEqual(marker) })
        else {
            return nil
        }
        guard let version = String(bytes: bytes[(start + 4)..<(start + 7)], encoding: .ascii) else { return nil }
        return Self(address: address, bytes: bytes, version: version)
    }
}
#endif
