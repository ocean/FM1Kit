#if os(macOS)
public import FM1Kit
import Foundation

extension FlashPlan {
    /// Plans installing a firmware from its package, as M-Flasher does: its image is written
    /// straight to the flash, without the firmware running or its update loader.
    ///
    /// The application area is written; the bootloader is kept unless `includingBootloader` is
    /// set, which also writes the package's boot area (M-VAVE's bootloader, for V15). Settings
    /// and voices stay as they are unless `erasingSettings` is set, which erases the settings
    /// and Bluetooth regions the package's firmware declares. A different firmware may not
    /// understand what another left there; restoring a backup made while it was installed goes
    /// back cleanly.
    ///
    /// - Parameters:
    ///   - package: A firmware package for the FM-1.
    ///   - current: The FM-1's flash as just read.
    ///   - includingBootloader: Also write the package's boot area.
    ///   - erasingSettings: Also erase the firmware's settings (`VM`) and Bluetooth (`BTIF`)
    ///     regions.
    /// - Returns: The plan.
    /// - Throws: ``FlashPlanError/notFirmware`` for an installer package,
    ///   ``FlashPlanError/wrongChipKey(_:)`` when its firmware wasn't made for this FM-1, or
    ///   ``FlashPlanError/settingsOverFactoryData``.
    public static func installing(
        _ package: FwscPackage,
        onto current: FlashBackup,
        includingBootloader: Bool = false,
        erasingSettings: Bool = false
    ) throws(FlashPlanError) -> Self {
        guard let image = package.flashImage else { throw .notFirmware }
        var warnings = try checkedFM1(current)
        let padded = image + [UInt8](repeating: 0xFF, count: FlashSession.flashSize - image.count)
        let incoming = FlashBackup(
            bytes: padded,
            uniqueID: nil,
            chipKey: current.chipKey,
            flashID: current.flashID,
            loaderVersion: "",
            date: Date()
        )
        guard incoming.firmware.files == .intact else { throw .wrongChipKey(current.chipKey) }

        let start = includingBootloader ? 0 : bootArea.upperBound
        var target = current.bytes
        target.replaceSubrange(start..<image.count, with: image[start...])
        var allowed = [start..<image.count]
        var notes = ["Installs \(package.product) (\(Self.describe(start..<image.count)))."]
        if includingBootloader {
            notes.append("Also writes the package's boot area, with its bootloader.")
        }
        let installed = current.regions()
        if !erasingSettings, !installed.isEmpty, installed != incoming.regions() {
            warnings.append(
                """
                The installed firmware keeps its settings in other places than \(package.product); what it \
                leaves behind can confuse the new one. Restoring a backup made while a firmware was \
                installed goes back to it cleanly.
                """)
        }
        if erasingSettings {
            for region in try incoming.settingsRegions() {
                guard !region.range.overlaps(factoryData), region.range.lowerBound >= bootArea.upperBound else {
                    throw .settingsOverFactoryData
                }
                target.replaceSubrange(region.range, with: repeatElement(0xFF, count: region.range.count))
                allowed.append(region.range)
                let what = region.name == "VM" ? "its settings" : "its Bluetooth pairings"
                notes.append("Erases \(what) (\(Self.describe(region.range))).")
            }
        } else if package.hasFactoryVoices {
            notes.append("The voice banks stay as they are; V15's factory voices can be restored once it's running.")
        }
        return try Self(
            purpose: .firmware(package.identity),
            original: current,
            target: target,
            allowed: allowed,
            notes: notes,
            warnings: warnings
        )
    }

    /// A range of flash addresses as text, such as "0x04000–0x92FFF".
    static func describe(_ range: Range<Int>) -> String {
        String(format: "0x%05X–0x%05X", range.lowerBound, range.upperBound - 1)
    }
}

extension FlashBackup {
    /// A region the firmware's app table declares, such as its settings (`VM`).
    struct Region: Hashable {
        let name: String
        let range: Range<Int>
    }

    /// The settings (`VM`) and Bluetooth (`BTIF`) regions the firmware declares, refusing any
    /// that isn't whole sectors inside the flash.
    func settingsRegions() throws(FlashPlanError) -> [Region] {
        let declared = applicationTable().filter { entry in
            [0x12, 0x92].contains(entry.attribute) && ["VM", "BTIF"].contains(entry.name) && entry.length > 0
        }
        return try declared.map { entry throws(FlashPlanError) in
            guard entry.address.isMultiple(of: FlashPlan.sectorLength),
                entry.length.isMultiple(of: FlashPlan.sectorLength), entry.address + entry.length <= bytes.count
            else {
                throw .settingsOverFactoryData
            }
            return Region(name: entry.name, range: entry.address..<(entry.address + entry.length))
        }
    }

    /// The regions the firmware declares that can be erased: sector-aligned, inside the flash.
    func regions() -> [Region] {
        applicationTable()
            .filter { [0x12, 0x92].contains($0.attribute) && $0.length > 0 }
            .filter { $0.address.isMultiple(of: FlashPlan.sectorLength) }
            .filter { $0.length.isMultiple(of: FlashPlan.sectorLength) }
            .filter { $0.address + $0.length <= bytes.count }
            .map { Region(name: $0.name, range: $0.address..<($0.address + $0.length)) }
            .sorted { $0.name < $1.name }
    }
}
#endif
