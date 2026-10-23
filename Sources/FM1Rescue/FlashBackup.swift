#if os(macOS)
public import FM1Kit
public import Foundation

/// The whole of an FM-1's flash, read in download mode: its bootloader, firmware, settings,
/// sounds and the unit's own factory data.
///
/// It's saved as M-Flasher saves backups (a raw 1 MB `.bin` and a `.json` describing it), so
/// either tool can restore it. A backup holds the unit's own factory data, so it's for putting
/// back on the same FM-1: ``uniqueID`` says which.
public struct FlashBackup: Sendable, Hashable {
    /// The flash, exactly as stored.
    public let bytes: [UInt8]
    /// The flash chip's unique ID, which tells one FM-1 from another; `nil` if it has none.
    public let uniqueID: String?
    /// The chip's encryption key.
    public let chipKey: UInt16
    /// The flash chip's JEDEC ID.
    public let flashID: UInt32
    /// The flash loader that read it.
    public let loaderVersion: String
    /// When it was read.
    public let date: Date

    /// The m-bootloader in the boot area, or `nil` for M-VAVE's or another bootloader.
    public var mBootloader: BootloaderImage? {
        Self.storedBootloader(in: bytes).flatMap(BootloaderImage.init(bytes:))
    }

    /// The bootloader in words, such as "m-bootloader 1.2-22e2559" or "M-VAVE's".
    public var bootloaderDescription: String {
        if let mBootloader { return "m-bootloader \(mBootloader.version)" }
        return Self.storedBootloader(in: bytes) == nil ? "unreadable" : "M-VAVE's"
    }

    /// Lower-case hex SHA-256 of the flash.
    public var sha256: String { FwscPackage.sha256Hex(bytes) }

    /// Where the bootloader's container is stored.
    static let bootloaderOffset = 0xA0
    /// The end of the boot area.
    static let bootAreaLength = 0x4000

    /// Reads the bootloader's container from the boot area: its 16-byte header and its code are
    /// each enciphered on their own.
    static func storedBootloader(in flash: [UInt8]) -> [UInt8]? {
        let start = bootloaderOffset
        guard flash.count >= bootAreaLength else { return nil }
        let header = decipher(flash[start..<(start + 16)])
        let length = Int(header[2]) | Int(header[3]) << 8
        let end = start + 16 + length
        guard header[0] == 1, header[1] == 0, length > 0, end <= bootAreaLength else { return nil }
        let container = header + decipher(flash[(start + 16)..<end])
        let expected = UInt16(header[14]) | UInt16(header[15]) << 8
        return ChipChecksum.crc16(header[0..<14]) == expected ? container : nil
    }

    /// JieLi's ENC cipher with key `0xFFFF`, its own inverse.
    static func decipher(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var key: UInt16 = 0xFFFF
        return bytes.map { byte in
            defer { key = key & 0x8000 == 0 ? key << 1 : (key << 1) ^ 0x1021 }
            return byte ^ UInt8(truncatingIfNeeded: key)
        }
    }

    // MARK: - Saving.

    /// Saves the backup as M-Flasher does, as `fm1-YYYYMMDD-HHMMSS.bin` and a `.json` beside it,
    /// never replacing an earlier backup.
    ///
    /// - Parameter folder: Where to save it; created if needed.
    /// - Returns: The `.bin` file and the `.json` file.
    /// - Throws: Any error creating the folder or writing a file.
    @discardableResult
    public func write(to folder: URL) throws -> (flash: URL, description: URL) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        var flashURL = folder.appending(path: "fm1-\(stamp).bin")
        var suffix = 2
        while FileManager.default.fileExists(atPath: flashURL.path)
            || FileManager.default.fileExists(
                atPath: flashURL.deletingPathExtension().appendingPathExtension("json").path)
        {
            flashURL = folder.appending(path: "fm1-\(stamp)-\(suffix).bin")
            suffix += 1
        }
        let descriptionURL = flashURL.deletingPathExtension().appendingPathExtension("json")
        try Data(bytes).write(to: flashURL, options: .withoutOverwriting)
        try Data(description(saved: stamp).utf8).write(to: descriptionURL, options: .withoutOverwriting)
        return (flashURL, descriptionURL)
    }

    /// The `.json`, laid out as M-Flasher writes it, which reads the unit ID back from it.
    func description(saved stamp: String) -> String {
        let fields: [(String, String)] = [
            ("model", "FM-1"),
            ("bootloader", bootloaderDescription),
            ("chip key", String(format: "0x%04X", chipKey)),
            ("flash", String(format: "0x%06X", flashID)),
            ("unit id", uniqueID ?? "–"),
            ("loader", "m-bootloader's flash loader \(loaderVersion)"),
            ("sha256", sha256),
            ("saved", stamp),
            ("tool", "FM1Kit"),
        ]
        let lines = fields.map { key, value in
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
                of: "\"", with: "\\\"")
            return "  \"\(key)\": \"\(escaped)\""
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }
}

extension FlashSession {
    /// Reads the whole flash twice and checks both reads against each other and against the
    /// chip's own CRC-32 of the flash, so a backup is never saved from a bad read.
    ///
    /// Nothing is written to the FM-1. Reading takes a few seconds on most USB ports.
    ///
    /// - Parameter progress: Called with the share read so far (0 to 1).
    /// - Returns: The backup, ready to ``FlashBackup/write(to:)``.
    /// - Throws: ``DownloadModeError/readsDiffer`` when the reads don't match, or another
    ///   ``DownloadModeError`` when the device stops answering.
    public func backUp(progress: (Double) -> Void = { _ in }) throws(DownloadModeError) -> FlashBackup {
        let size = Self.flashSize
        progress(0)
        let first = try read(0..<size) { progress(Double($0) / Double(size * 2)) }
        let second = try read(0..<size) { progress(0.5 + Double($0) / Double(size * 2)) }
        let checksum = try crc32(of: 0..<size)
        guard first == second, ChipChecksum.crc32(first) == checksum else { throw .readsDiffer }
        progress(1)
        return FlashBackup(
            bytes: first,
            uniqueID: uniqueID,
            chipKey: chipKey,
            flashID: flashID,
            loaderVersion: loaderVersion,
            date: Date()
        )
    }
}
#endif
