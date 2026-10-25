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

/// A custom firmware FM1Kit names in backups.
struct KnownFirmware {
    let identity: String
    /// Text its code holds, naming the firmware and its version.
    let marker: String
    let name: String
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
        ///
        /// Forks share identity numbers (HYP-1 numbers its builds as AMB-1 does), so a custom
        /// firmware is named only when its code also carries the name and version it shows.
        public let name: String?
        /// The identity that goes with ``name``, for a custom firmware.
        let namedIdentity: String?

        init(files: FirmwareFiles, identities: [String], isOfficialV15: Bool, code: [UInt8] = []) {
            self.files = files
            self.identities = identities
            self.isOfficialV15 = isOfficialV15
            let known = Self.knownFirmwares.first { firmware in
                identities.contains(firmware.identity) && code.firstRange(of: Array(firmware.marker.utf8)) != nil
            }
            name = isOfficialV15 ? "V15" : known?.name
            namedIdentity = known?.identity
        }

        /// The firmware in words, such as "V15 (FM-1_015)", "AMB-1 1.3 (FM-1_7010300)" or
        /// "unknown, naming FM-1_2147".
        public var description: String {
            if files == .missing { return "none" }
            if isOfficialV15 { return "V15 (FM-1_015)" }
            if let name, let namedIdentity { return "\(name) (\(namedIdentity))" }
            guard let last = identities.last else { return "unknown" }
            let names = identities.count == 1 ? last : identities.dropLast().joined(separator: ", ") + " and \(last)"
            return "unknown, naming \(names)"
        }

        /// Custom firmwares by the identity their code names, alongside V15's `FM-1_015`, and the
        /// text their code shows with it: only versions read from a real FM-1.
        static let knownFirmwares = [
            KnownFirmware(identity: "FM-1_916", marker: "FELUCCA v1.6.1", name: "Felucca 1.6.1"),
            KnownFirmware(identity: "FM-1_7010300", marker: "AMB-1 1.3", name: "AMB-1 1.3"),
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
            isOfficialV15: FwscPackage.sha256Hex(code) == Self.officialV15ApplicationSHA256,
            code: code
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
        applicationArea.code()
    }

    /// The SHA-256 of V15's `app.bin`, deciphered, as read from a real FM-1 running V15.
    static let officialV15ApplicationSHA256 = "306e47065f35d7a7a05ada7f5dd092f6e770952054f33f0a86b75fd10ffe3203"
    /// Where the app area starts, after the boot area.
    static let applicationArea = ApplicationArea.start
    /// The attribute of a file in the app area's table, rather than a region.
    static let fileAttribute = ApplicationArea.fileAttribute
    /// The flash's erase size.
    static let sectorLength = 0x1000

    /// An entry in the app area's file table.
    typealias TableEntry = ApplicationArea.Entry

    /// The backup's app area.
    var applicationArea: ApplicationArea {
        ApplicationArea(flash: bytes, chipKey: chipKey)
    }

    /// The app area's file table: its files (such as `app.bin`) and the regions it declares.
    func applicationTable() -> [TableEntry] {
        applicationArea.table()
    }

    /// Deciphers bytes of the app area, from `offset` within it.
    func applicationBytes(at offset: Int, count: Int) -> [UInt8] {
        applicationArea.bytes(at: offset, count: count)
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
