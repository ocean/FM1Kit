#if os(macOS)
public import FM1Kit
public import Foundation

// The planning rules follow M-Flasher's `ops.rs` and `formats.rs` (MIT License, Copyright (c)
// 2026 Julius Vitkauskas; see Resources/NOTICE.md) and m-bootloader's specification (§11).

/// A change to an FM-1's flash in download mode, worked out before anything is written: the
/// flash it should hold afterwards, and the 4 KB sectors that differ from what it holds now.
///
/// A plan is made against a ``FlashBackup`` of the FM-1 read in the same session, which is also
/// the way back: save it before writing. Only the sectors that differ are erased and written,
/// and each run of them is checked against the chip's CRC-32 afterwards
/// (``FlashSession/write(_:progress:)``). The FM-1's last sector holds its own factory data,
/// which is never taken from another unit's backup.
public struct FlashPlan: Sendable, Hashable {
    /// What a plan does.
    public enum Purpose: Sendable, Hashable {
        /// Puts a full backup back.
        case restore
        /// Installs a bootloader: its description, such as "m-bootloader 1.2-22e2559".
        case bootloader(String)
        /// Installs a firmware from its package.
        case firmware(FM1Identity)
    }

    /// What it does.
    public let purpose: Purpose
    /// The flash it was planned against.
    public let original: FlashBackup
    /// The flash the FM-1 should hold afterwards.
    public let target: [UInt8]
    /// The start of every 4 KB sector that changes, in order.
    public let sectors: [Int]
    /// What it does, in sentences.
    public let notes: [String]
    /// What to know before confirming, in sentences.
    public let warnings: [String]

    /// The FM-1's flash sector size.
    public static let sectorLength = 0x1000
    /// The FM-1's own factory data, kept when restoring another unit's backup.
    public static let factoryData = 0xF_F000..<0x10_0000
    /// The boot area at the start of the flash.
    static let bootArea = 0..<0x4000
    /// Where the bootloader is stored.
    static let bootloaderStart = 0xA0

    /// True when the flash already holds the target, so there's nothing to write.
    public var isEmpty: Bool { sectors.isEmpty }

    /// The sectors that change, joined into runs of neighbours.
    public var runs: [Range<Int>] {
        var runs: [Range<Int>] = []
        for sector in sectors {
            if let last = runs.last, last.upperBound == sector {
                runs[runs.count - 1] = last.lowerBound..<(sector + Self.sectorLength)
            } else {
                runs.append(sector..<(sector + Self.sectorLength))
            }
        }
        return runs
    }

    /// Plans a change, refusing one that would touch anything outside `allowed`.
    init(
        purpose: Purpose,
        original: FlashBackup,
        target: [UInt8],
        allowed: [Range<Int>],
        notes: [String],
        warnings: [String] = []
    ) throws(FlashPlanError) {
        var sectors: [Int] = []
        for sector in stride(from: 0, to: target.count, by: Self.sectorLength) {
            let range = sector..<(sector + Self.sectorLength)
            guard original.bytes[range] != target[range] else { continue }
            guard allowed.contains(where: { $0.contains(range.lowerBound) && range.upperBound <= $0.upperBound })
            else {
                throw .outsideAllowedRange(sector)
            }
            sectors.append(sector)
        }
        self.purpose = purpose
        self.original = original
        self.target = target
        self.sectors = sectors
        self.notes = notes
        self.warnings = warnings
    }

    // MARK: - Restoring.

    /// Plans putting a full backup back.
    ///
    /// A backup of the same FM-1 (by the flash chip's unique ID) is restored whole, bootloader
    /// included. Another unit's keeps this FM-1's own factory data. Without unique IDs to
    /// compare, a backup counts as this unit's when its factory data matches or this FM-1's is
    /// blank, which isn't proof.
    ///
    /// - Parameters:
    ///   - backup: The backup to put back.
    ///   - current: The FM-1's flash as just read.
    /// - Returns: The plan.
    /// - Throws: ``FlashPlanError/notFullBackup(_:)`` when the backup isn't 1 MB.
    public static func restoring(_ backup: FlashBackup, onto current: FlashBackup) throws(FlashPlanError) -> Self {
        guard backup.bytes.count == FlashSession.flashSize else { throw .notFullBackup(backup.bytes.count) }
        guard backup.model != .otherModel else { throw .notAnFM1 }
        var warnings = try checkedFM1(current)
        let factory = factoryData
        let isSameUnit: Bool
        let isKnown: Bool
        if let theirs = backup.uniqueID, let ours = current.uniqueID {
            isSameUnit = theirs == ours
            isKnown = true
        } else {
            isSameUnit =
                backup.bytes[factory] == current.bytes[factory] || current.bytes[factory].allSatisfy { $0 == 0xFF }
            isKnown = false
        }
        var target = backup.bytes
        var notes: [String] = []
        if isSameUnit {
            notes.append(
                backup.bytes[bootArea] == current.bytes[bootArea]
                    ? "The whole flash is restored; the boot area already matches, so the bootloader isn't written."
                    : "The whole flash is restored, the bootloader included.")
            if backup.bytes[factory] != current.bytes[factory] {
                let state = current.bytes[factory].allSatisfy { $0 == 0xFF } ? "blank" : "different from the backup's"
                warnings.append(
                    "This FM-1's factory data is \(state); the backup's is restored. Use only a backup of this FM-1.")
            }
        } else {
            target.replaceSubrange(factory, with: current.bytes[factory])
            warnings.append(
                """
                This backup \(isKnown ? "is from" : "seems to come from") another FM-1: its factory data \
                isn't restored, and this FM-1 keeps its own.
                """)
        }
        return try Self(
            purpose: .restore,
            original: current,
            target: target,
            allowed: isSameUnit ? [0..<FlashSession.flashSize] : [0..<factory.lowerBound],
            notes: notes,
            warnings: warnings
        )
    }

    /// Refuses flash that shows it isn't an FM-1's.
    ///
    /// When the flash doesn't say, the FM-1's flash chip is enough, with a warning.
    ///
    /// - Returns: Any warning.
    static func checkedFM1(_ current: FlashBackup) throws(FlashPlanError) -> [String] {
        switch current.model {
        case .fm1: return []
        case .otherModel: throw .notAnFM1
        case .unknown:
            guard FlashSession.fm1FlashIDs.contains(current.flashID) else { throw .notAnFM1 }
            return [
                """
                The flash doesn't show which model this is, but its flash chip is the FM-1's. Go on \
                only on an FM-1.
                """
            ]
        }
    }
}

/// Why a change to the flash wasn't planned.
///
/// Nothing has been written when one is thrown.
public enum FlashPlanError: Error, Hashable, LocalizedError {
    /// The backup isn't 1 MB; this is its size.
    case notFullBackup(Int)
    /// The bootloader is built for another board; this is the board it names.
    case wrongBoard(String)
    /// The package is an installer, not a firmware.
    case notFirmware
    /// The package's boot area holds no bootloader FM1Kit can read, or holds m-bootloader.
    case noBootloader
    /// The FM-1's boot area has no file table FM1Kit can read, so the bootloader can't be
    /// replaced on its own.
    case unreadableBootArea
    /// The bootloader doesn't fit the boot area; this is its size.
    case bootloaderTooLarge(Int)
    /// This m-bootloader version wouldn't start with the FM-1's boot configuration, which needs
    /// `minimum` or newer.
    case bootloaderTooOld(String, minimum: String)
    /// The package's firmware wasn't made for this FM-1's chip key, so it wouldn't start.
    case wrongChipKey(UInt16)
    /// A firmware declares saved data over the boot area, `0xFC000` onwards or the factory data,
    /// or not in whole sectors, so it can't be erased safely.
    case settingsOverFactoryData
    /// The flash, or the backup, shows it's another model's, or nothing shows it's an FM-1's.
    case notAnFM1
    /// A change fell outside what the plan may touch: a mistake in FM1Kit. This is the sector.
    case outsideAllowedRange(Int)

    /// What happened and what to do next.
    public var errorDescription: String? {
        switch self {
        case .notFullBackup(let size):
            "This isn't a full flash backup: it's \(size) bytes, not 1 MB. Nothing was written."
        case .wrongBoard(let board):
            "This bootloader is built for \(board), not the FM-1. Nothing was written."
        case .notFirmware:
            "This package holds an installer, not a firmware. Nothing was written."
        case .noBootloader:
            "This package doesn't hold M-VAVE's bootloader. Nothing was written."
        case .unreadableBootArea:
            """
            The FM-1's boot area can't be read, so its bootloader can't be replaced on its own. \
            Install firmware with its bootloader instead, or restore a backup. Nothing was written.
            """
        case .bootloaderTooLarge(let size):
            "This bootloader is \(size) bytes, too large for the boot area. Nothing was written."
        case .bootloaderTooOld(let version, let minimum):
            """
            m-bootloader \(version) would stop at BAD CONFIG on every start with this FM-1's boot \
            configuration. Install m-bootloader \(minimum) or newer. Nothing was written.
            """
        case .wrongChipKey(let key):
            String(
                format: """
                    This firmware wasn't made for this FM-1's chip key (0x%04X), so it wouldn't start. \
                    Nothing was written.
                    """, key)
        case .settingsOverFactoryData:
            """
            One of the firmwares declares saved data where it can't be erased safely, so nothing \
            was written. Install it without erasing saved data.
            """
        case .notAnFM1:
            """
            This doesn't look like an FM-1's flash: the bootloader or firmware on it, or in the \
            backup, is another model's. Nothing was written.
            """
        case .outsideAllowedRange(let sector):
            String(
                format: "FM1Kit planned a change outside what it may touch (0x%05X), so nothing was written.", sector)
        }
    }
}
#endif
