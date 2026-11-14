#if os(macOS)
public import FM1Kit
import Foundation

extension FlashPlan {
    /// Plans installing a firmware from its package, as M-Flasher does: its image is written
    /// straight to the flash, without the firmware running or its update loader.
    ///
    /// The application area is written; the bootloader is kept unless `includingBootloader` is
    /// set, which also writes the package's boot area (M-VAVE's bootloader, for V15).
    ///
    /// Saved data stays as it is unless `erasingSavedData` is set. Each firmware declares where
    /// it keeps its settings, presets, projects and Bluetooth pairings, and many share the same
    /// space in different formats, so what one leaves behind can confuse the next. Some write
    /// outside what they declare too: V16 leaves data in V15's `USR` region that makes V15 play
    /// one note at a time. Erasing clears everything from the end of the new image up to
    /// `0xFBFFF`, which covers every region the firmwares seen so far declare (such as `VM`,
    /// `BTIF`, `USR` with V15's voice banks, and V16's `SEQ64`), so the incoming firmware starts
    /// from its defaults. It never touches the boot area, `0xFC000` onwards (which holds data
    /// under every firmware, though none declares it) or the factory data.
    /// Restoring a backup made while a firmware was installed goes back to it exactly. When the
    /// incoming firmware is V15, its factory voices and the rest of its `USR` data are written
    /// back into the erased `USR` region, as the factory left them, so it isn't silent.
    ///
    /// A package that carries its resources in fm1-base's form (``FwscPackage/resources``) has
    /// them written where its part says, after erasing saved data, or without erasing when that
    /// flash is blank past any resources already there. Anything else there may be an older build's
    /// projects not yet moved, so the resources are left out, and the plan says to install the
    /// firmware again over USB-MIDI once it's running: its update loader writes them. The same goes
    /// for resources in another form, such as Melodee's.
    ///
    /// - Parameters:
    ///   - package: A firmware package for the FM-1.
    ///   - current: The FM-1's flash as just read.
    ///   - includingBootloader: Also write the package's boot area.
    ///   - erasingSavedData: Also erase every firmware's saved data, up to `0xFBFFF`.
    /// - Returns: The plan.
    /// - Throws: ``FlashPlanError/notFirmware`` for an installer package,
    ///   ``FlashPlanError/wrongChipKey(_:)`` when its firmware wasn't made for this FM-1, or
    ///   ``FlashPlanError/settingsOverFactoryData``.
    public static func installing(
        _ package: FwscPackage,
        onto current: FlashBackup,
        includingBootloader: Bool = false,
        erasingSavedData: Bool = false
    ) throws(FlashPlanError) -> Self {
        try installing(
            package,
            onto: current,
            includingBootloader: includingBootloader,
            erasingSavedData: erasingSavedData,
            extras: Extras(factoryUserData: package.factoryUserData())
        )
    }

    /// What an install writes besides the firmware.
    struct Extras {
        /// V15's `USR` data, written into the `USR` region the firmware declares when erasing
        /// saved data.
        var factoryUserData: [UInt8]?
        /// Write the package's resources; the Transporter can't reach them.
        var writesResources = true
    }

    /// Plans installing a firmware, with these extras.
    static func installing(
        _ package: FwscPackage,
        onto current: FlashBackup,
        includingBootloader: Bool,
        erasingSavedData: Bool,
        extras: Extras
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
        if !erasingSavedData, let warning = Self.settingsWarning(current, incoming, product: package.product) {
            warnings.append(warning)
        }
        if erasingSavedData {
            let (ranges, erasingNotes) = try Self.eraseSavedData(
                of: [current, incoming],
                after: image.count,
                userRegion: incoming.regions().first(where: { $0.name == "USR" })?.range,
                factoryUserData: extras.factoryUserData,
                in: &target
            )
            allowed += ranges
            notes += erasingNotes
        } else if package.hasFactoryVoices {
            notes.append("The voice banks stay as they are; V15's factory voices can be restored once it's running.")
        }
        let resources =
            extras.writesResources
            ? Self.addResources(of: package, over: current, erasing: erasingSavedData, to: &target) : nil
        if let resources {
            allowed.append(resources)
            notes.append("Writes its resources (\(Self.describe(resources))).")
        }
        var plan = try Self(
            purpose: .firmware(package.identity),
            original: current,
            target: target,
            allowed: allowed,
            notes: notes,
            warnings: warnings
        )
        if resources == nil, package.resources != nil || package.carriesOtherResources {
            plan.afterwards.append(Self.resourcesAfterwards(package))
        }
        return plan
    }

    /// A warning when the installed firmware keeps its settings in other places than the incoming
    /// one, or `nil`.
    static func settingsWarning(_ current: FlashBackup, _ incoming: FlashBackup, product: String) -> String? {
        let installed = current.regions()
        guard !installed.isEmpty, installed != incoming.regions() else { return nil }
        return """
            The installed firmware keeps its settings in other places than \(product); what it \
            leaves behind can confuse the new one. Restoring a backup made while a firmware was \
            installed goes back to it cleanly.
            """
    }

    /// Erases every firmware's saved data in `target`, then writes `factoryUserData` into the
    /// `USR` region when it fits; returns the ranges erased and notes saying so.
    static func eraseSavedData(
        of flashes: [FlashBackup],
        after start: Int,
        userRegion: Range<Int>?,
        factoryUserData: [UInt8]?,
        in target: inout [UInt8]
    ) throws(FlashPlanError) -> (ranges: [Range<Int>], notes: [String]) {
        let ranges = try savedDataRanges(of: flashes, after: start)
        var notes: [String] = []
        for range in ranges {
            target.replaceSubrange(range, with: repeatElement(0xFF, count: range.count))
        }
        if !ranges.isEmpty {
            notes.append("Erases saved data (\(ranges.map(describe).joined(separator: ", "))).")
        }
        if let factoryUserData, let user = userRegion, factoryUserData.count <= user.count,
            ranges.contains(where: { $0.contains(user.lowerBound) && $0.upperBound >= user.upperBound })
        {
            let written = user.lowerBound..<(user.lowerBound + factoryUserData.count)
            target.replaceSubrange(written, with: factoryUserData)
            notes.append("Writes V15's factory voices and data back (\(describe(written))).")
        }
        return (ranges, notes)
    }

    /// Puts the package's resources (in fm1-base's form) into `target` and returns the flash they
    /// take, or returns `nil` when it has none or they can't go there.
    ///
    /// Without erasing, they go only into flash that's blank past any resources already there:
    /// anything else may be an older build's projects not yet moved.
    static func addResources(
        of package: FwscPackage,
        over current: FlashBackup,
        erasing: Bool,
        to target: inout [UInt8]
    ) -> Range<Int>? {
        guard let resources = package.resources, let range = resources.flashRange else { return nil }
        guard erasing || isBlankPastResources(current.bytes[range]) else { return nil }
        target.replaceSubrange(
            range, with: resources.bytes + repeatElement(0xFF, count: range.count - resources.bytes.count))
        return range
    }

    /// True when `flash` is blank past the sectors of any resources whose header starts it.
    static func isBlankPastResources(_ flash: ArraySlice<UInt8>) -> Bool {
        let claimed = ResourceRegion.claimedLength(flash) ?? 0
        return flash.dropFirst((claimed + sectorLength - 1) / sectorLength * sectorLength).allSatisfy { $0 == 0xFF }
    }

    /// What to do once a firmware is running whose resources a plan leaves out.
    static func resourcesAfterwards(_ package: FwscPackage) -> String {
        """
        Its resources (such as samples) aren't written here. Once \(package.product) is running, install it again \
        over USB-MIDI, and its update loader writes them: `fm1probe install FILE.fwsc`.
        """
    }

    /// Where data is kept that no firmware declares but every one leaves in place, from `0xFC000`
    /// up to the factory data.
    static let undeclaredData = 0xF_C000..<factoryData.lowerBound

    /// The saved data to erase: everything from `start`, where the new image ends, up to
    /// `0xFC000`, once the regions these firmwares declare have been checked to lie inside it.
    ///
    /// - Throws: ``FlashPlanError/settingsOverFactoryData`` for a region that isn't whole
    ///   sectors inside the flash, or that reaches the boot area, `0xFC000` onwards or the
    ///   factory data.
    static func savedDataRanges(of flashes: [FlashBackup], after start: Int) throws(FlashPlanError) -> [Range<Int>] {
        for flash in flashes {
            for region in try flash.savedDataRegions() {
                guard region.range.lowerBound >= bootArea.upperBound, !region.range.overlaps(undeclaredData),
                    !region.range.overlaps(factoryData)
                else {
                    throw .settingsOverFactoryData
                }
            }
        }
        let lower = (start + sectorLength - 1) / sectorLength * sectorLength
        return lower < undeclaredData.lowerBound ? [lower..<undeclaredData.lowerBound] : []
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

    /// Every region the firmware declares for saved data, refusing any that isn't whole sectors
    /// inside the flash.
    ///
    /// That's every declared region but the protected firmware area (`PRCT`): its settings
    /// (`VM`), Bluetooth pairings (`BTIF`), voice banks (`USR`) or V16's patterns (`SEQ64`).
    func savedDataRegions() throws(FlashPlanError) -> [Region] {
        let declared = applicationTable().filter { entry in
            [0x12, 0x92].contains(entry.attribute) && entry.name != "PRCT" && entry.length > 0
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
