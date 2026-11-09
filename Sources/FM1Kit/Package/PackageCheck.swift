import Foundation

/// A firmware package checked before release: whether it will start, where it keeps its saved
/// data, which firmwares will install it, and how people can switch away from it.
///
/// Every finding is read from the package alone; nothing is sent to an FM-1. Routes between
/// firmwares follow how each update check works (see ``LeavingGuide``), and not every one has
/// been tried on an FM-1.
///
/// ```swift
/// let report = PackageCheck(package)
/// for finding in report.findings { print(finding.outcome, finding.summary) }
/// if !report.passes { exit(1) }
/// ```
public struct PackageCheck: Sendable, Hashable {
    /// How a finding came out.
    public enum Outcome: String, Sendable, Hashable, Codable, Comparable {
        /// All is well.
        case pass
        /// Worth knowing, with nothing to fix.
        case note
        /// Works, but people may run into it.
        case warning
        /// The package shouldn't be released like this.
        case failure

        /// Orders outcomes from best to worst.
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

        private var rank: Int {
            switch self {
            case .pass: 0
            case .note: 1
            case .warning: 2
            case .failure: 3
            }
        }
    }

    /// What a finding is about.
    public enum Topic: String, Sendable, Hashable, Codable, CaseIterable {
        /// The identity the firmware reports.
        case identity
        /// Whether the firmware is enciphered for the FM-1's chip key, so it starts.
        case chipKey
        /// Which flash chips the firmware's code checks for.
        case flashChips
        /// Where the firmware keeps its settings and other saved data.
        case savedData
        /// Which firmwares will install the package.
        case installing
        /// How people can switch from it to other firmwares.
        case leaving
        /// Whether the FM-1 Transporter can put it back on an FM-1 that doesn't start.
        case recovery
    }

    /// One thing found.
    public struct Finding: Sendable, Hashable, Codable {
        /// What it's about.
        public let topic: Topic
        /// How it came out.
        public let outcome: Outcome
        /// What was found, in a sentence or two.
        public let summary: String
    }

    /// Everything found, in the order of ``Topic``.
    public let findings: [Finding]

    /// True when nothing failed.
    public var passes: Bool { !findings.contains { $0.outcome == .failure } }

    /// The worst outcome among the findings.
    public var worst: Outcome { findings.map(\.outcome).max() ?? .pass }

    /// Checks a package.
    ///
    /// - Parameter package: The package to check; an installer package, such as m-bootloader's,
    ///   gets a single note, since it brings no firmware.
    public init(_ package: FwscPackage) {
        guard package.isFirmware, let image = package.flashImage else {
            findings = [
                Finding(
                    topic: .installing,
                    outcome: .note,
                    summary: "This package brings an installer, not a firmware, so there's nothing more to check.")
            ]
            return
        }
        var findings: [Finding] = []
        findings += Self.identity(of: package)
        let area = ApplicationArea(flash: image, chipKey: ApplicationArea.fm1ChipKey)
        findings.append(Self.chipKey(of: area))
        findings.append(Self.flashChips(of: package))
        findings += Self.savedData(of: area, imageLength: image.count)
        findings += Self.installing(package)
        findings += Self.leaving(package)
        findings.append(Self.recovery(imageLength: image.count))
        self.findings = findings
    }

    // MARK: - The checks.

    static func identity(of package: FwscPackage) -> [Finding] {
        let identity = package.identity
        if let official = OfficialFirmware.matching(package) {
            return [Finding(topic: .identity, outcome: .pass, summary: "\(official.name), verified by its SHA-256.")]
        }
        if identity.isOfficial {
            return [
                Finding(
                    topic: .identity,
                    outcome: .warning,
                    summary: """
                        It reports \(identity.text), M-VAVE's own identity, so apps can't tell it from \
                        M-VAVE's firmware. Give it an identity of its own.
                        """)
            ]
        }
        if identity.isOpenFirmware {
            return [
                Finding(
                    topic: .identity,
                    outcome: .note,
                    summary: "It reports \(identity.text), in the range of M-VAVE's open firmware.")
            ]
        }
        return [Finding(topic: .identity, outcome: .pass, summary: "It reports \(identity.text).")]
    }

    static func chipKey(of area: ApplicationArea) -> Finding {
        let files = area.table().filter { $0.attribute == ApplicationArea.fileAttribute }
        guard let app = files.first(where: { $0.name == "app.bin" }) else {
            return Finding(
                topic: .chipKey,
                outcome: .failure,
                summary: String(
                    format: """
                        Its app area doesn't read with the FM-1's chip key (0x%04X): it has no app.bin. \
                        It wouldn't start.
                        """, ApplicationArea.fm1ChipKey))
        }
        let damaged = files.filter { file in
            ApplicationArea.start + file.address + file.length > area.flash.count
                || FirmwareContainer.crc16(area.bytes(at: file.address, count: file.length)) != file.dataCRC
        }
        guard damaged.isEmpty else {
            return Finding(
                topic: .chipKey,
                outcome: .failure,
                summary:
                    "These files' checksums fail: \(damaged.map(\.name).joined(separator: ", ")). It wouldn't start.")
        }
        return Finding(
            topic: .chipKey,
            outcome: .pass,
            summary: String(
                format: "Enciphered for the FM-1's chip key (0x%04X); app.bin is %d bytes and its checksums pass.",
                ApplicationArea.fm1ChipKey,
                app.length))
    }

    static func flashChips(of package: FwscPackage) -> Finding {
        switch package.flashChipSupport {
        case .bothChips:
            return Finding(
                topic: .flashChips,
                outcome: .pass,
                summary: "Its code checks for both FM-1 flash chips, so it saves on FM-1s with the newer one too.")
        case .firstChipOnly:
            return Finding(
                topic: .flashChips,
                outcome: .warning,
                summary: String(
                    format: """
                        Its code checks for the first FM-1s' flash chip (0x%06X) alone. On FM-1s sold since \
                        autumn 2026, with the newer chip (0x%06X), it will probably keep saves only until \
                        switched off. Accept both IDs.
                        """,
                    FM1FlashChip.p25q80,
                    FM1FlashChip.uc25hq80))
        case .noCheck:
            return Finding(
                topic: .flashChips,
                outcome: .pass,
                summary: "Its code doesn't check which flash chip it has, as V15's doesn't, so it should save on both.")
        case nil:
            return Finding(
                topic: .flashChips,
                outcome: .note,
                summary: "Its code couldn't be read to see which flash chips it checks for.")
        }
    }

    /// Where saved data may go: after the boot area and before `0xFC000`, which holds data under
    /// every firmware though none declares it, and the factory data.
    static let savedDataLimit = 0xF_C000
    /// The flash sector size: saved data is erased in whole sectors.
    static let sectorLength = 0x1000
    /// Where V15 keeps its saved data.
    static let v15Regions: [String: Range<Int>] = [
        "VM": 0x9_3000..<0xE_9000, "BTIF": 0xE_9000..<0xE_A000, "USR": 0xE_A000..<0xF_C000,
    ]

    static func savedData(of area: ApplicationArea, imageLength: Int) -> [Finding] {
        let regions = area.table().filter { [0x12, 0x92].contains($0.attribute) && $0.name != "PRCT" && $0.length > 0 }
        guard !regions.isEmpty else {
            return [
                Finding(
                    topic: .savedData,
                    outcome: .note,
                    summary: "It declares no saved data, so switching firmware leaves nothing of it behind.")
            ]
        }
        var findings: [Finding] = []
        let listed = regions.map { "\($0.name) \(describe($0.address..<($0.address + $0.length)))" }
        for region in regions {
            let range = region.address..<(region.address + region.length)
            let problem: String? =
                if !region.address.isMultiple(of: sectorLength) || !region.length.isMultiple(of: sectorLength) {
                    "isn't whole 4 KB sectors, so it can't be erased without touching its neighbours"
                } else if range.lowerBound < imageLength {
                    "overlaps the firmware image, which ends at \(String(format: "0x%05X", imageLength))"
                } else if range.upperBound > savedDataLimit {
                    """
                    reaches 0xFC000 or beyond, where every firmware leaves data and the FM-1 keeps its own \
                    factory data
                    """
                } else {
                    nil
                }
            if let problem {
                findings.append(
                    Finding(
                        topic: .savedData, outcome: .failure, summary: "\(region.name) \(describe(range)) \(problem)."))
            }
        }
        guard findings.isEmpty else { return findings }
        findings.append(
            Finding(
                topic: .savedData,
                outcome: .pass,
                summary: "It declares \(listed.joined(separator: ", ")), "
                    + "all whole sectors clear of the image and 0xFC000 onwards."
            ))
        let declared = Dictionary(
            regions.map { ($0.name, $0.address..<($0.address + $0.length)) }, uniquingKeysWith: { first, _ in first })
        let sharedWithV15 = declared.filter { name, range in
            v15Regions.values.contains { $0.overlaps(range) } && v15Regions[name] != range
        }
        if !sharedWithV15.isEmpty {
            findings.append(
                Finding(
                    topic: .savedData,
                    outcome: .note,
                    summary: """
                        \(sharedWithV15.keys.sorted().joined(separator: ", ")) overlaps space V15 uses differently, \
                        so whatever V15 left there will be read as this firmware's data until it's overwritten. \
                        Check the data's format or a marker before trusting it.
                        """))
        }
        return findings
    }

    /// The flash the FM-1 Transporter writes ends here.
    static let transporterLimit = 0x9_3000

    static func recovery(imageLength: Int) -> Finding {
        imageLength <= transporterLimit
            ? Finding(
                topic: .recovery,
                outcome: .pass,
                summary: "Its image ends at or before 0x92FFF, "
                    + "so the FM-1 Transporter can put it back on an FM-1 that doesn't start."
            )
            : Finding(
                topic: .recovery,
                outcome: .note,
                summary: String(
                    format: """
                        Its image runs to 0x%05X, past 0x92FFF, where the FM-1 Transporter stops writing, so it \
                        can't put this firmware back; download mode can.
                        """, imageLength - 1))
    }

    /// A range of flash addresses as text, such as "0x93000–0xE8FFF".
    static func describe(_ range: Range<Int>) -> String {
        String(format: "0x%05X–0x%05X", range.lowerBound, range.upperBound - 1)
    }
}
