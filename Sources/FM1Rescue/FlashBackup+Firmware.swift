#if os(macOS)
import FM1Kit
import Foundation

// The app area's layout and the per-block cipher follow M-Flasher's `formats.rs` (MIT License,
// Copyright (c) 2026 Julius Vitkauskas; see Resources/NOTICE.md).

/// Whether the firmware's files in a flash backup are whole, as m-bootloader's menu reports them.
public enum FirmwareFiles: Sendable, Hashable {
    /// Every file's checksum matches.
    case intact
    /// A file's checksum fails; the firmware may still start.
    case damaged
    /// A file has erased sectors in it: a write was interrupted.
    case incomplete
    /// The app area has no files: no firmware is installed.
    case missing
}

extension FlashBackup {
    /// The firmware stored in a backup, as far as the flash shows it.
    public struct FirmwareCheck: Sendable, Hashable {
        /// Whether the firmware's files are whole.
        public let files: FirmwareFiles
        /// Every identity the firmware's code names, such as `FM-1_015`, in order.
        ///
        /// A firmware can name more than the one it reports, so this doesn't say which it reports.
        public let identities: [String]
        /// Whether it's M-VAVE's V15, byte for byte.
        public let isOfficialV15: Bool

        /// The firmware's name, for V15 and the other firmwares tried on a real FM-1, such as
        /// "Felucca 1.6.1". `nil` for others.
        public var name: String? {
            if isOfficialV15 { return "V15" }
            return identities.lazy.compactMap { Self.knownFirmwares[$0] }.first
        }

        /// The firmware in words, such as "V15 (FM-1_015)", "AMB-1 1.3 (FM-1_7010300)" or
        /// "unknown, naming FM-1_2147".
        public var description: String {
            if files == .missing { return "none" }
            if isOfficialV15 { return "V15 (FM-1_015)" }
            if let name, let identity = identities.first(where: { Self.knownFirmwares[$0] == name }) {
                return "\(name) (\(identity))"
            }
            guard let last = identities.last else { return "unknown" }
            let names = identities.count == 1 ? last : identities.dropLast().joined(separator: ", ") + " and \(last)"
            return "unknown, naming \(names)"
        }

        /// Custom firmwares by the identity their code names, alongside V15's `FM-1_015`: only
        /// versions read from a real FM-1.
        static let knownFirmwares = [
            "FM-1_916": "Felucca 1.6.1",
            "FM-1_7010300": "AMB-1 1.3",
        ]

        /// The files' state in words, as M-Flasher writes it in a backup's `.json`.
        public var filesDescription: String {
            switch files {
            case .intact: "OK"
            case .damaged: "DAMAGED (a checksum fails; it may still start)"
            case .incomplete: "INCOMPLETE (partly erased: an interrupted write)"
            case .missing: "none installed"
            }
        }
    }

    /// The firmware stored in the backup: whether its files are whole and what it names itself.
    public var firmware: FirmwareCheck {
        let table = applicationTable()
        let files = table.filter { $0.attribute == Self.fileAttribute }
        guard !files.isEmpty else { return FirmwareCheck(files: .missing, identities: [], isOfficialV15: false) }
        let state = files.first { !isWhole($0) }.map { isPartlyErased($0) ? FirmwareFiles.incomplete : .damaged }
        guard let code = applicationCode() else {
            return FirmwareCheck(files: state ?? .intact, identities: [], isOfficialV15: false)
        }
        return FirmwareCheck(
            files: state ?? .intact,
            identities: Self.identities(in: code),
            isOfficialV15: FwscPackage.sha256Hex(code) == Self.officialV15ApplicationSHA256
        )
    }

    /// Which model the flash shows it's from.
    public enum Model: Sendable, Hashable {
        /// Its m-bootloader is built for the FM-1, or its firmware names FM-1 identities.
        case fm1
        /// Its bootloader or firmware is another model's, such as the SMK-37, which has the same
        /// chip.
        case otherModel
        /// Nothing in the flash says.
        case unknown
    }

    /// Which model the flash shows it's from.
    public var model: Model {
        if let mBootloader { return mBootloader.board == BootloaderImage.fm1Board ? .fm1 : .otherModel }
        guard let code = applicationCode() else { return .unknown }
        if code.firstRange(of: Array("SMK-37".utf8)) != nil { return .otherModel }
        return Self.identities(in: code).isEmpty ? .unknown : .fm1
    }

    /// The firmware's `app.bin`, deciphered, if the app area's table names one inside the flash.
    func applicationCode() -> [UInt8]? {
        guard let app = applicationTable().first(where: { $0.name == "app.bin" }),
            Self.applicationArea + app.address + app.length <= bytes.count
        else {
            return nil
        }
        return applicationBytes(at: app.address, count: app.length)
    }

    /// The SHA-256 of V15's `app.bin`, deciphered, as read from a real FM-1 running V15.
    static let officialV15ApplicationSHA256 = "306e47065f35d7a7a05ada7f5dd092f6e770952054f33f0a86b75fd10ffe3203"
    /// Where the app area starts, after the boot area.
    static let applicationArea = 0x4000
    /// The attribute of a file in the app area's table, rather than a region.
    static let fileAttribute: UInt8 = 0x82
    /// The flash's erase size.
    static let sectorLength = 0x1000

    /// An entry in the app area's file table.
    struct TableEntry {
        /// The CRC-16 of the file's deciphered bytes.
        let dataCRC: UInt16
        /// Where it starts, from the start of the app area for files.
        let address: Int
        let length: Int
        let attribute: UInt8
        let name: String
    }

    /// The app area's file table: its files (such as `app.bin`) and the regions it declares.
    func applicationTable() -> [TableEntry] {
        var entries: [TableEntry] = []
        for index in 0..<16 {
            let raw = applicationBytes(at: 32 * index, count: 32)
            guard raw.count == 32, ChipChecksum.crc16(raw[2...]) == Self.littleEndian(raw, at: 0, byteCount: 2)
            else { break }
            let name = raw[16...].prefix { $0 != 0 }
            entries.append(
                TableEntry(
                    dataCRC: UInt16(Self.littleEndian(raw, at: 2, byteCount: 2)),
                    address: Self.littleEndian(raw, at: 4, byteCount: 4),
                    length: Self.littleEndian(raw, at: 8, byteCount: 4),
                    attribute: raw[12],
                    name: String(bytes: name, encoding: .ascii) ?? ""
                ))
        }
        return entries
    }

    /// Deciphers bytes of the app area, which is enciphered in 32-byte blocks, each with the chip
    /// key mixed with the block's offset.
    func applicationBytes(at offset: Int, count: Int) -> [UInt8] {
        var plain: [UInt8] = []
        plain.reserveCapacity(count + 64)
        var block = offset - offset % 32
        while block < offset + count, Self.applicationArea + block + 32 <= bytes.count {
            let start = Self.applicationArea + block
            plain += Self.decipher(bytes[start..<(start + 32)], key: chipKey ^ UInt16(truncatingIfNeeded: block >> 2))
            block += 32
        }
        return Array(plain.dropFirst(offset % 32).prefix(count))
    }

    func isWhole(_ file: TableEntry) -> Bool {
        Self.applicationArea + file.address + file.length <= bytes.count
            && ChipChecksum.crc16(applicationBytes(at: file.address, count: file.length)) == file.dataCRC
    }

    /// Whether any sector the file covers is erased, as an interrupted write leaves it.
    func isPartlyErased(_ file: TableEntry) -> Bool {
        let start = Self.applicationArea + file.address
        let end = min(start + file.length, bytes.count)
        return stride(from: start - start % Self.sectorLength, to: end, by: Self.sectorLength).contains { sector in
            bytes[sector..<min(sector + Self.sectorLength, bytes.count)].allSatisfy { $0 == 0xFF }
        }
    }

    /// Every `FM-1_` identity in the code, such as `FM-1_015` or `FM-1_8000012`, in order.
    static func identities(in code: [UInt8]) -> [String] {
        let prefix = Array("FM-1_".utf8)
        var found: Set<String> = []
        var index = 0
        while let start = code[index...].firstRange(of: prefix)?.upperBound {
            let digits = code[start...].prefix { (0x30...0x39).contains($0) }
            if (3...8).contains(digits.count) {
                found.insert("FM-1_" + (String(bytes: digits, encoding: .ascii) ?? ""))
            }
            index = start
        }
        return found.sorted()
    }

    static func littleEndian(_ bytes: [UInt8], at offset: Int, byteCount: Int) -> Int {
        (0..<byteCount).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
    }
}
#endif
