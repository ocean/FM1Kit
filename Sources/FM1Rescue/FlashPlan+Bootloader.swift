#if os(macOS)
public import FM1Kit
import Foundation

// The boot area's layout follows m-bootloader's specification (§5.2, §5.3, §11.2) and
// M-Flasher's `formats.rs` (MIT License, Copyright (c) 2026 Julius Vitkauskas; see
// Resources/NOTICE.md).

extension FlashPlan {
    /// Plans installing m-bootloader from its `.boot` file.
    ///
    /// Only the bootloader and its record in the boot area are replaced; the FM-1's own boot
    /// configuration stays where it is, as m-bootloader's specification asks (§11.2). V16's is
    /// further on than V15's, after its larger bootloader, and m-bootloader 2 shortens it and
    /// moves it to the end of the boot area. Versions that wouldn't start with the FM-1's
    /// configuration are refused: before 1.3 with V16's, before 2.0 with a shortened one.
    ///
    /// - Parameters:
    ///   - bootloader: The bootloader, which must be built for the FM-1.
    ///   - current: The FM-1's flash as just read.
    /// - Returns: The plan, warning when the FM-1 has the newer flash chip, on which m-bootloader
    ///   has hardly been tried.
    /// - Throws: ``FlashPlanError/wrongBoard(_:)``, ``FlashPlanError/unreadableBootArea``,
    ///   ``FlashPlanError/bootloaderTooLarge(_:)`` or
    ///   ``FlashPlanError/bootloaderTooOld(_:minimum:)``.
    public static func installing(_ bootloader: BootloaderImage, onto current: FlashBackup)
        throws(FlashPlanError) -> Self
    {
        guard bootloader.board == BootloaderImage.fm1Board else { throw .wrongBoard(bootloader.board) }
        if let configuration = bootConfiguration(Array(current.bytes[bootArea])),
            let minimum = configuration.minimumMBootloader,
            releaseNumbers(bootloader.version).lexicographicallyPrecedes(releaseNumbers(minimum))
        {
            throw .bootloaderTooOld(bootloader.version, minimum: minimum)
        }
        var warnings: [String] = []
        if current.flashID == FM1FlashChip.uc25hq80 {
            warnings.append(
                """
                This FM-1 has the newer flash chip (0xB36014), on which m-bootloader has hardly been \
                tried: one such FM-1 didn't start after m-bootloader 1.1 or 1.2 was installed. The \
                backup saved before writing is the way back.
                """)
        }
        return try installingBootloader(
            bootloader.bytes, described: "m-bootloader \(bootloader.version)", onto: current, warnings: warnings)
    }

    /// Plans putting back M-VAVE's bootloader from a firmware package, such as V15's, in place
    /// of m-bootloader, keeping the firmware.
    ///
    /// The package's whole boot area is written, its configuration included, as an official
    /// update writes it: M-VAVE's bootloader reads the configuration, which m-bootloader 2 may
    /// have shortened, and V16's differs from V15's.
    ///
    /// - Parameters:
    ///   - package: A firmware package whose boot area holds M-VAVE's bootloader.
    ///   - current: The FM-1's flash as just read.
    /// - Returns: The plan.
    /// - Throws: ``FlashPlanError/notFirmware``, ``FlashPlanError/noBootloader`` or
    ///   ``FlashPlanError/unreadableBootArea``.
    public static func installingBootloader(from package: FwscPackage, onto current: FlashBackup)
        throws(FlashPlanError) -> Self
    {
        guard let image = package.flashImage else { throw .notFirmware }
        let padded = image + [UInt8](repeating: 0xFF, count: max(0, bootArea.upperBound - image.count))
        guard let container = FlashBackup.storedBootloader(in: padded), isIntactContainer(container) else {
            throw .noBootloader
        }
        guard BootloaderImage(bytes: container) == nil else { throw .noBootloader }
        let area = Array(padded[bootArea])
        guard bootConfiguration(area) != nil else { throw .unreadableBootArea }
        let warnings = try checkedFM1(current)
        return try Self(
            purpose: .bootloader("M-VAVE's bootloader"),
            original: current,
            target: area + current.bytes[bootArea.upperBound...],
            allowed: [bootArea],
            notes: [
                """
                Installs M-VAVE's bootloader with the package's boot configuration, as an official \
                update does. Only the boot area is written.
                """
            ],
            warnings: warnings
        )
    }

    static func installingBootloader(
        _ container: [UInt8], described description: String, onto current: FlashBackup, warnings: [String] = []
    ) throws(FlashPlanError) -> Self {
        let checked = try checkedFM1(current)
        let area = try bootAreaHolding(container, in: current.bytes)
        return try Self(
            purpose: .bootloader(description),
            original: current,
            target: area + current.bytes[bootArea.upperBound...],
            allowed: [bootArea],
            notes: [
                "Installs \(description). Only the boot area is written; the FM-1's own boot configuration is kept."
            ],
            warnings: checked + warnings
        )
    }

    /// The boot area with `container` in place of its bootloader, keeping everything else in it.
    static func bootAreaHolding(_ container: [UInt8], in flash: [UInt8]) throws(FlashPlanError) -> [UInt8] {
        guard isIntactContainer(container) else { throw .noBootloader }
        var area = Array(flash[bootArea])
        let table = bootTable(area)
        guard table.count >= 3, table[0].name == "uboot.boot", table[0].address == bootloaderStart,
            let configuration = bootConfiguration(area)
        else {
            throw .unreadableBootArea
        }
        guard bootloaderStart + container.count <= configuration.start else {
            throw .bootloaderTooLarge(container.count)
        }
        var record = table[0].fields
        let crc = ChipChecksum.crc16(container)
        record.replaceSubrange(2..<4, with: [UInt8(crc & 0xFF), UInt8(crc >> 8)])
        record.replaceSubrange(4..<8, with: littleEndian(bootloaderStart))
        record.replaceSubrange(8..<12, with: littleEndian(container.count))
        let recordCRC = ChipChecksum.crc16(record[2...])
        record.replaceSubrange(0..<2, with: [UInt8(recordCRC & 0xFF), UInt8(recordCRC >> 8)])
        area.replaceSubrange(0x20..<0x40, with: FlashBackup.decipher(record[...]))
        var stored = FlashBackup.decipher(container[0..<16]) + FlashBackup.decipher(container[16...])
        stored += [UInt8](repeating: 0xFF, count: configuration.start - bootloaderStart - stored.count)
        area.replaceSubrange(bootloaderStart..<configuration.start, with: stored)
        return area
    }

    /// Whether a bootloader container's header and code checksums match: one bank, its code
    /// straight after the 16-byte header, as m-bootloader's specification checks (§11.2).
    static func isIntactContainer(_ container: [UInt8]) -> Bool {
        guard container.count > 16 else { return false }
        let field = { (offset: Int, count: Int) in FlashBackup.littleEndian(container, at: offset, byteCount: count) }
        return field(0, 2) == 1 && field(8, 4) == 16 && 16 + field(2, 2) == container.count
            && field(12, 2) == Int(ChipChecksum.crc16(container[16...]))
            && field(14, 2) == Int(ChipChecksum.crc16(container[0..<14]))
    }

    /// The release numbers at the start of a version, such as `[1, 3]` for `1.3-6c321e9`.
    static func releaseNumbers(_ version: String) -> [Int] {
        version.prefix { $0 != "-" }.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// A record in the boot area's file table.
    struct BootRecord {
        /// The record, deciphered.
        let fields: [UInt8]
        let address: Int
        let name: String
    }

    /// The boot configuration (`isd_config.ini`): where it is, and what decides which bootloaders
    /// start with it.
    struct BootConfiguration {
        /// Where it starts: `0x38D0` after V15's bootloader, `0x3938` after V16's.
        let start: Int
        /// Its length: 699 bytes in V15's, 34 or 96 once m-bootloader 2 has shortened it.
        let length: Int
        /// The clock it asks for (`SYS_CLK`) in Hz, if it says: 360 MHz, or 320 MHz in V16's.
        let clock: Int?

        /// The oldest m-bootloader that starts with it, if any doesn't: 1.2 stops at
        /// `BAD CONFIG` with V16's clock, and 1.3 and older with m-bootloader 2.0's 34 bytes.
        var minimumMBootloader: String? {
            if length < 96 { return "2.0" }
            if clock == 320_000_000 { return "1.3" }
            return nil
        }
    }

    /// The boot area's configuration, or `nil` if its record is missing or points outside the
    /// boot area.
    static func bootConfiguration(_ area: [UInt8]) -> BootConfiguration? {
        let table = bootTable(area)
        guard table.count >= 2, table[1].name == "isd_config.ini" else { return nil }
        let start = table[1].address
        let length = FlashBackup.littleEndian(table[1].fields, at: 8, byteCount: 4)
        guard start >= bootloaderStart, length >= 34, start + length <= bootArea.upperBound else { return nil }
        // After the 34-byte chip-key record: a value length, a key ending in a zero, the value.
        let blob = Array(area[start..<(start + length)])
        var clock: Int?
        var index = 34
        while index < blob.count, let end = blob[(index + 1)...].firstIndex(of: 0) {
            let valueLength = Int(blob[index])
            guard end + 1 + valueLength <= blob.count else { break }
            if blob[(index + 1)..<end].elementsEqual("SYS_CLK".utf8), valueLength == 4 {
                clock = FlashBackup.littleEndian(blob, at: end + 1, byteCount: 4)
            }
            index = end + 1 + valueLength
        }
        return BootConfiguration(start: start, length: length, clock: clock)
    }

    /// The boot area's file table, or nothing if its header is damaged.
    static func bootTable(_ area: [UInt8]) -> [BootRecord] {
        let header = FlashBackup.decipher(area[0..<32])
        guard ChipChecksum.crc16(header[2...]) == UInt16(FlashBackup.littleEndian(header, at: 0, byteCount: 2))
        else {
            return []
        }
        var records: [BootRecord] = []
        for start in stride(from: 0x20, to: bootloaderStart, by: 0x20) {
            let fields = FlashBackup.decipher(area[start..<(start + 32)])
            guard ChipChecksum.crc16(fields[2...]) == UInt16(FlashBackup.littleEndian(fields, at: 0, byteCount: 2))
            else {
                break
            }
            let name = String(bytes: fields[16...].prefix { $0 != 0 }, encoding: .ascii) ?? ""
            records.append(
                BootRecord(
                    fields: fields, address: FlashBackup.littleEndian(fields, at: 4, byteCount: 4), name: name))
        }
        return records
    }

    static func littleEndian(_ value: Int) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
#endif
