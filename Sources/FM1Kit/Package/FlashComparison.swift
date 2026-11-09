import Foundation

/// Two flash images compared part by part: the boot area, the app area's table, each file it
/// lists, each region it declares for saved data (such as `VM` or `USR`), the data every
/// firmware keeps from `0xFC000` and the factory data from `0xFF000`, and whatever lies outside
/// them.
///
/// It works on anything that starts at flash address 0: a flash backup, or a firmware package's
/// image (``FwscPackage/compared(with:)``). Files are compared deciphered, so two images
/// enciphered for different chip keys still match when their files do.
public struct FlashComparison: Sendable {
    /// How a part differs.
    public enum Outcome: String, Sendable, Codable {
        /// The same in both.
        case same
        /// In both, but different.
        case changed
        /// Only in the second.
        case added
        /// Only in the first.
        case removed
    }

    /// One part of the flash and how it differs.
    public struct Part: Sendable, Codable, Equatable {
        /// What the part is, such as `boot area`, `file app.bin` or `region VM`.
        public let name: String
        /// Where it is in flash; for a part that moved, where it is in the second image.
        public let range: Range<Int>?
        /// Whether it's the same, changed, added or removed.
        public let outcome: Outcome
        /// What differs, such as `CRC 0x1234 → 0x5678` or `0x2000 bytes differ: 0x93000–0x94FFF`.
        public let detail: String

        /// Where it is, such as `0x04000–0x05FFF`, or an empty string.
        public var rangeText: String {
            range.map(FlashComparison.describe) ?? ""
        }
    }

    /// Every part, in flash order, the same ones included.
    public let parts: [Part]

    /// True when no part differs.
    public var isSame: Bool { parts.allSatisfy { $0.outcome == .same } }

    /// The flash's erase size, by which differences are counted.
    static let sectorLength = 0x1000
    /// Areas past every firmware's saved data, compared when the images reach them, as backups do.
    static let fixedAreas = [
        ("undeclared data", 0xF_C000..<0xF_F000),
        ("factory data", 0xF_F000..<0x10_0000),
    ]
    /// How many differing runs a part's detail lists before it stops.
    static let listedRuns = 4

    /// Compares two images.
    ///
    /// - Parameters:
    ///   - first: The first image, from flash address 0, and the chip key it's enciphered with.
    ///   - second: The second image and its chip key.
    public init(_ first: (bytes: [UInt8], chipKey: UInt16), _ second: (bytes: [UInt8], chipKey: UInt16)) {
        let areas = (
            ApplicationArea(flash: first.bytes, chipKey: first.chipKey),
            ApplicationArea(flash: second.bytes, chipKey: second.chipKey)
        )
        let tables = (areas.0.table(), areas.1.table())
        var parts: [(start: Int, part: Part)] = []
        var claimed: [Range<Int>] = []

        let boot = 0..<ApplicationArea.start
        claimed.append(boot)
        parts.append((boot.lowerBound, Self.compareBytes("boot area", boot, first.bytes, second.bytes)))

        let tableRange = ApplicationArea.start..<(ApplicationArea.start + 32 * max(tables.0.count, tables.1.count, 1))
        claimed.append(tableRange)
        parts.append((tableRange.lowerBound, Self.compareTables(tableRange, tables.0, tables.1)))

        let files = (
            tables.0.filter { $0.attribute == ApplicationArea.fileAttribute },
            tables.1.filter { $0.attribute == ApplicationArea.fileAttribute }
        )
        for name in Self.names(files.0, files.1) {
            let entries = (files.0.first { $0.name == name }, files.1.first { $0.name == name })
            for entry in [entries.0, entries.1].compactMap({ $0 }) {
                claimed.append(Self.flashRange(ofFile: entry))
            }
            let start = (entries.1 ?? entries.0).map { ApplicationArea.start + $0.address } ?? 0
            parts.append((start, Self.compareFiles(name, entries, areas)))
        }

        let regions = (tables.0.filter(Self.isSavedData), tables.1.filter(Self.isSavedData))
        for name in Self.names(regions.0, regions.1) {
            let entries = (regions.0.first { $0.name == name }, regions.1.first { $0.name == name })
            for entry in [entries.0, entries.1].compactMap({ $0 }) {
                claimed.append(entry.address..<(entry.address + entry.length))
            }
            let start = (entries.1 ?? entries.0)?.address ?? 0
            parts.append((start, Self.compareRegions(name, entries, first.bytes, second.bytes)))
        }

        let length = max(first.bytes.count, second.bytes.count)
        for (name, range) in Self.fixedAreas where range.upperBound <= length {
            claimed.append(range)
            parts.append((range.lowerBound, Self.compareBytes(name, range, first.bytes, second.bytes)))
        }

        let rest = Self.unclaimed(0..<length, claimed)
        parts.append((Int.max, Self.compareRest(rest, first.bytes, second.bytes)))

        self.parts = parts.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element.part)
    }

    // MARK: - Parts.

    private static func compareBytes(_ name: String, _ range: Range<Int>, _ first: [UInt8], _ second: [UInt8])
        -> Part
    {
        let present = (first.count > range.lowerBound, second.count > range.lowerBound)
        if !present.0 || !present.1 {
            let outcome: Outcome = present.0 == present.1 ? .same : (present.1 ? .added : .removed)
            return Part(name: name, range: range, outcome: outcome, detail: "")
        }
        let runs = differingRuns(in: [range], first, second)
        return Part(
            name: name, range: range, outcome: runs.isEmpty ? .same : .changed, detail: describeRuns(runs))
    }

    private static func compareTables(
        _ range: Range<Int>, _ first: [ApplicationArea.Entry], _ second: [ApplicationArea.Entry]
    ) -> Part {
        if first == second {
            return Part(name: "app table", range: range, outcome: .same, detail: "\(first.count) entries")
        }
        let names = (Set(first.map(\.name)), Set(second.map(\.name)))
        var changes: [String] = []
        let added = names.1.subtracting(names.0).sorted()
        let removed = names.0.subtracting(names.1).sorted()
        if !added.isEmpty { changes.append("adds " + added.joined(separator: ", ")) }
        if !removed.isEmpty { changes.append("drops " + removed.joined(separator: ", ")) }
        let changed = names.0.intersection(names.1).sorted().filter { name in
            first.first { $0.name == name } != second.first { $0.name == name }
        }
        if !changed.isEmpty { changes.append("changes " + changed.joined(separator: ", ")) }
        if changes.isEmpty { changes.append("same entries in a different order") }
        return Part(name: "app table", range: range, outcome: .changed, detail: changes.joined(separator: "; "))
    }

    private static func compareFiles(
        _ name: String, _ entries: (ApplicationArea.Entry?, ApplicationArea.Entry?),
        _ areas: (ApplicationArea, ApplicationArea)
    ) -> Part {
        switch entries {
        case (let first?, let second?):
            let range = flashRange(ofFile: second)
            let bytes = (
                areas.0.bytes(at: first.address, count: first.length),
                areas.1.bytes(at: second.address, count: second.length)
            )
            var changes: [String] = []
            if first.length != second.length { changes.append("\(first.length) → \(second.length) bytes") }
            if first.dataCRC != second.dataCRC {
                changes.append(String(format: "CRC 0x%04X → 0x%04X", first.dataCRC, second.dataCRC))
            }
            if first.address != second.address {
                changes.append("moved from " + describe(flashRange(ofFile: first)))
            }
            if bytes.0 != bytes.1, first.length == second.length {
                let differing = zip(bytes.0, bytes.1).filter { $0 != $1 }.count
                changes.append("\(differing) of \(first.length) bytes differ")
            } else if bytes.0 != bytes.1, changes.isEmpty {
                changes.append("contents differ")
            }
            return Part(
                name: "file \(name)", range: range, outcome: changes.isEmpty ? .same : .changed,
                detail: changes.isEmpty
                    ? String(format: "%d bytes, CRC 0x%04X", first.length, first.dataCRC)
                    : changes.joined(separator: ", "))
        case (let first?, nil):
            return Part(
                name: "file \(name)", range: flashRange(ofFile: first), outcome: .removed,
                detail: "\(first.length) bytes")
        case (nil, let second?):
            return Part(
                name: "file \(name)", range: flashRange(ofFile: second), outcome: .added,
                detail: "\(second.length) bytes")
        case (nil, nil):
            return Part(name: "file \(name)", range: nil, outcome: .same, detail: "")
        }
    }

    private static func compareRegions(
        _ name: String, _ entries: (ApplicationArea.Entry?, ApplicationArea.Entry?), _ first: [UInt8],
        _ second: [UInt8]
    ) -> Part {
        let ranges = (
            entries.0.map { $0.address..<($0.address + $0.length) },
            entries.1.map { $0.address..<($0.address + $0.length) }
        )
        switch ranges {
        case (let firstRange?, let secondRange?) where firstRange != secondRange:
            return Part(
                name: "region \(name)", range: secondRange, outcome: .changed,
                detail: "declared at \(describe(firstRange)) in the first")
        case (let range?, _?):
            let inBoth = range.upperBound <= first.count && range.upperBound <= second.count
            guard inBoth else {
                return Part(name: "region \(name)", range: range, outcome: .same, detail: "declared alike")
            }
            let runs = differingRuns(in: [range], first, second)
            let erased = (isErased(first, range), isErased(second, range))
            var detail = describeRuns(runs)
            if !runs.isEmpty, erased.0 != erased.1 {
                detail += erased.0 ? "; erased in the first" : "; erased in the second"
            }
            return Part(name: "region \(name)", range: range, outcome: runs.isEmpty ? .same : .changed, detail: detail)
        case (let range?, nil):
            return Part(name: "region \(name)", range: range, outcome: .removed, detail: "declared only in the first")
        case (nil, let range?):
            return Part(name: "region \(name)", range: range, outcome: .added, detail: "declared only in the second")
        case (nil, nil):
            return Part(name: "region \(name)", range: nil, outcome: .same, detail: "")
        }
    }

    private static func compareRest(_ ranges: [Range<Int>], _ first: [UInt8], _ second: [UInt8]) -> Part {
        var details: [String] = []
        let runs = differingRuns(in: ranges, first, second)
        if !runs.isEmpty { details.append(describeRuns(runs)) }
        if first.count != second.count {
            details.append("the images are \(hex(first.count)) and \(hex(second.count)) bytes long")
        }
        return Part(
            name: "everything else", range: nil, outcome: details.isEmpty ? .same : .changed,
            detail: details.isEmpty ? "the same" : details.joined(separator: "; "))
    }

    // MARK: - Helpers.

    /// True for a region the firmware keeps saved data in, such as `VM` or `USR`: not the
    /// protected firmware area (`PRCT`), which the files fill, nor the table's other entries.
    static func isSavedData(_ entry: ApplicationArea.Entry) -> Bool {
        [0x12, 0x92].contains(entry.attribute) && entry.name != "PRCT" && entry.length > 0
    }

    /// Where a file the table lists is in flash.
    static func flashRange(ofFile entry: ApplicationArea.Entry) -> Range<Int> {
        (ApplicationArea.start + entry.address)..<(ApplicationArea.start + entry.address + entry.length)
    }

    /// Names in either list, in the order they first appear.
    private static func names(_ first: [ApplicationArea.Entry], _ second: [ApplicationArea.Entry]) -> [String] {
        var seen: Set<String> = []
        return (first + second).map(\.name).filter { seen.insert($0).inserted }
    }

    /// The parts of `whole` that no range in `claimed` covers.
    static func unclaimed(_ whole: Range<Int>, _ claimed: [Range<Int>]) -> [Range<Int>] {
        var free: [Range<Int>] = []
        var position = whole.lowerBound
        for range in claimed.sorted(by: { $0.lowerBound < $1.lowerBound }) where range.upperBound > position {
            if range.lowerBound > position { free.append(position..<min(range.lowerBound, whole.upperBound)) }
            position = max(position, range.upperBound)
            if position >= whole.upperBound { break }
        }
        if position < whole.upperBound { free.append(position..<whole.upperBound) }
        return free
    }

    /// The runs of sectors (clipped to `ranges`) in which the images differ, where both have bytes.
    static func differingRuns(in ranges: [Range<Int>], _ first: [UInt8], _ second: [UInt8]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        let common = min(first.count, second.count)
        for range in ranges {
            var sector = range.lowerBound - range.lowerBound % sectorLength
            while sector < min(range.upperBound, common) {
                let piece = max(sector, range.lowerBound)..<min(sector + sectorLength, range.upperBound, common)
                if first[piece] != second[piece] {
                    if let last = runs.last, last.upperBound == piece.lowerBound {
                        runs[runs.count - 1] = last.lowerBound..<piece.upperBound
                    } else {
                        runs.append(piece)
                    }
                }
                sector += sectorLength
            }
        }
        return runs
    }

    private static func isErased(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        bytes[range].allSatisfy { $0 == 0xFF }
    }

    private static func describeRuns(_ runs: [Range<Int>]) -> String {
        guard !runs.isEmpty else { return "the same" }
        let bytes = runs.reduce(0) { $0 + $1.count }
        let listed = runs.prefix(listedRuns).map(describe).joined(separator: ", ")
        let more = runs.count > listedRuns ? " and \(runs.count - listedRuns) more" : ""
        return "\(hex(bytes)) bytes differ: \(listed)\(more)"
    }

    static func describe(_ range: Range<Int>) -> String {
        String(format: "0x%05X–0x%05X", range.lowerBound, range.upperBound - 1)
    }

    private static func hex(_ length: Int) -> String {
        String(format: "0x%X", length)
    }
}

extension FwscPackage {
    /// Compares this package's firmware image with another's, part by part.
    ///
    /// - Parameter other: The second package.
    /// - Returns: The comparison, or `nil` when either is an installer package, with no image.
    public func compared(with other: FwscPackage) -> FlashComparison? {
        guard let first = flashImage, let second = other.flashImage else { return nil }
        return FlashComparison(
            (first, ApplicationArea.fm1ChipKey), (second, ApplicationArea.fm1ChipKey))
    }
}
