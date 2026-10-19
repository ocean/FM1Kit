public import Foundation

/// A project from M-VAVE's open firmware: one slot's, or the workspace being edited.
///
/// Version 4 projects are 4064 bytes and version 3 (before arpeggiator settings) 4048. In a file,
/// a project has a 16-byte header: `FM1P`, the version, three zero bytes, then the project's
/// length and CRC-32 (both LE32). M-VAVE's workbench reads and writes these `.fm1` files, so a
/// backup's projects can be restored with it.
public struct OpenFirmwareProject: Sendable, Hashable {
    /// The project as the firmware stores it.
    public let bytes: [UInt8]

    /// The lengths a project can have: version 3's and version 4's.
    static let lengths = [4048, 4064]
    /// Where a project records its version.
    static let versionOffset = 3852
    /// What a project file starts with.
    static let fileMagic = Array("FM1P".utf8)
    /// The length of a project file's header.
    static let fileHeaderLength = 16

    /// Checks a project's length and version.
    ///
    /// Fails unless it's 4048 bytes of version 3 or 4064 bytes of version 4.
    ///
    /// - Parameter bytes: The project as the firmware stores it.
    public init?(bytes: some Collection<UInt8>) {
        let bytes = Array(bytes)
        guard let version = Self.version(of: bytes) else { return nil }
        guard bytes[Self.versionOffset] == version else { return nil }
        self.bytes = bytes
    }

    /// Reads a `.fm1` project file, as M-VAVE's workbench writes.
    ///
    /// Fails unless the header, length and CRC-32 match.
    ///
    /// - Parameter fileData: The file's contents.
    public init?(fileData: Data) {
        let file = [UInt8](fileData)
        let header = Self.fileHeaderLength
        guard
            file.count > header, file.starts(with: Self.fileMagic), file[5...7].allSatisfy({ $0 == 0 }),
            let project = Self(bytes: file[header...]),
            file[4] == project.version,
            Int(FM1Message.readLittleEndian(file, at: 8, byteCount: 4)) == project.bytes.count,
            FM1Message.readLittleEndian(file, at: 12, byteCount: 4) == CRC32.checksum(project.bytes)
        else {
            return nil
        }
        self = project
    }

    /// The project's format version: 3 or 4.
    public var version: UInt8 {
        bytes[Self.versionOffset]
    }

    /// The project as a `.fm1` file, as M-VAVE's workbench writes.
    public func fileData() -> Data {
        var file = Self.fileMagic + [version, 0, 0, 0]
        file += FM1Message.littleEndian(UInt32(bytes.count), byteCount: 4)
        file += FM1Message.littleEndian(CRC32.checksum(bytes), byteCount: 4)
        return Data(file + bytes)
    }

    /// The version a project of this length must have, or `nil` for any other length.
    private static func version(of bytes: [UInt8]) -> UInt8? {
        switch bytes.count {
        case lengths[0]: 3
        case lengths[1]: 4
        default: nil
        }
    }
}

/// What ``FM1Updater/backUpOpenFirmware(progress:)`` read from an FM-1 running M-VAVE's open
/// firmware: its project slots, the workspace and the sample bank.
///
/// It doesn't hold open firmware's settings, its per-slot tuning tables (from Open V13), or
/// anything another firmware stores: each firmware keeps its data in its own format, so a
/// backup is only for putting back on open firmware.
public struct OpenFirmwareBackup: Sendable, Hashable {
    /// One of the FM-1's project slots.
    public struct Slot: Sendable, Hashable {
        /// The slot's position, from 0; the FM-1 shows it from 1.
        public let index: Int
        /// The project's name, or `nil` when the slot is empty.
        public let name: String?
        /// The project, or `nil` when the slot is empty.
        public let project: OpenFirmwareProject?
    }

    /// What the FM-1 reported.
    public let identity: FM1Identity
    /// When the backup was made.
    public let date: Date
    /// The slot the workspace was loaded from, from 0.
    public let currentSlot: Int
    /// The project being edited, including any unsaved changes.
    public let workspace: OpenFirmwareProject
    /// Every project slot, in order.
    public let slots: [Slot]
    /// The sample bank as the firmware stores it, or `nil` when it's empty or unreadable.
    ///
    /// M-VAVE's workbench reads and writes it as a `.fm1s` file.
    public let samples: Data?

    /// Writes the backup to a folder, creating it if needed.
    ///
    /// The folder gets `workspace.fm1`, `slot-01.fm1` to `slot-16.fm1` for the slots that aren't
    /// empty, `samples.fm1s` when there's a sample bank, and `backup.json` describing them. The
    /// project and sample files are the formats M-VAVE's workbench reads.
    ///
    /// - Parameter folder: Where to write; existing files with the same names are replaced.
    /// - Returns: The files written.
    /// - Throws: Any error creating the folder or writing a file.
    @discardableResult
    public func write(to folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var written: [URL] = []
        func save(_ data: Data, as name: String) throws {
            let url = folder.appending(path: name)
            try data.write(to: url, options: .atomic)
            written.append(url)
        }

        try save(workspace.fileData(), as: Self.workspaceFileName)
        var slotEntries: [OpenFirmwareBackupManifest.Slot] = []
        for slot in slots {
            guard let project = slot.project else {
                slotEntries.append(OpenFirmwareBackupManifest.Slot(slot: slot.index + 1, name: nil, file: nil))
                continue
            }
            let name = Self.slotFileName(slot.index)
            try save(project.fileData(), as: name)
            slotEntries.append(OpenFirmwareBackupManifest.Slot(slot: slot.index + 1, name: slot.name, file: name))
        }
        if let samples {
            try save(samples, as: Self.samplesFileName)
        }

        let manifest = OpenFirmwareBackupManifest(
            identity: identity.text,
            date: date,
            currentSlot: currentSlot + 1,
            workspace: Self.workspaceFileName,
            slots: slotEntries,
            samples: samples == nil ? nil : Self.samplesFileName,
            sampleBytes: samples?.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try save(try encoder.encode(manifest), as: Self.manifestFileName)
        return written
    }

    static let workspaceFileName = "workspace.fm1"
    static let samplesFileName = "samples.fm1s"
    static let manifestFileName = "backup.json"

    /// A slot's file name, numbered from 1 as the FM-1 shows it.
    static func slotFileName(_ index: Int) -> String {
        "slot-" + String(format: "%02d", index + 1) + ".fm1"
    }
}

/// What a backup's `backup.json` records.
struct OpenFirmwareBackupManifest: Codable {
    /// One slot: its number from 1, and its name and file unless it's empty.
    struct Slot: Codable {
        var slot: Int
        var name: String?
        var file: String?
    }

    var identity: String
    var date: Date
    var currentSlot: Int
    var workspace: String
    var slots: [Slot]
    var samples: String?
    var sampleBytes: Int?
}

/// The standard CRC-32 (as in zlib), which open firmware's project library checks.
enum CRC32 {
    /// The checksum of some bytes.
    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
