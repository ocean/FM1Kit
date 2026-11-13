/// How a firmware installs other firmwares once it's running, read from its package by
/// ``FwscPackage/updateCode``.
public enum UpdateCode: String, Sendable, Hashable, Codable, CaseIterable {
    /// M-VAVE's, in V15, V16 and M-VAVE's open firmware. V15 takes any package.
    case mVave
    /// Felucca's original check: it takes firmwares on Felucca's platform, but a package that
    /// brings M-VAVE's update loader only onto the bootloader that package brings, and never
    /// m-bootloader's installer.
    case feluccaOriginalCheck
    /// The fixed check (felucca-bsp from October 2026, such as MIDIMON 0.4 and LOOM-8 0.8): it
    /// takes any package whose bootloader the FM-1 can start.
    case feluccaFixedCheck
    /// Felucca's original check, but recognising V15 by the SHA-256 of its flash image, as
    /// SikkenWorks' ETCH, BEETLE and B1 do: it takes V15 onto any bootloader.
    case recognisesV15
    /// A loader of its own for every package, as Quixotic7's TransitFM1 and RemoteFM1 have: it
    /// takes V15 onto any bootloader, and keeps the bootloader the FM-1 has. It refuses firmware
    /// images of any size but V15's, so V16 and open firmware.
    case ownLoader
    /// Update code FM1Kit doesn't recognise.
    case unknown
}

/// The bootloader in an FM-1's boot area, as far as switching firmware goes.
public enum FM1BootArea: String, Sendable, Hashable, Codable, CaseIterable {
    /// M-VAVE's, as V15 installs it.
    case v15
    /// M-VAVE's, as V16 installs it: 12,655 of its 16,384 bytes differ from V15's.
    case v16
    /// M-VAVE's, as its open firmware installs it.
    case openFirmware
    /// m-bootloader.
    case mBootloader
}

/// Where a person might want to go from a firmware.
public enum LeavingDestination: String, Sendable, Hashable, Codable, CaseIterable {
    /// M-VAVE's V15.
    case v15
    /// M-VAVE's V16.
    case v16
    /// M-VAVE's open firmware.
    case openFirmware
    /// Another firmware on Felucca's platform, which most custom firmwares are.
    case feluccaPlatform
    /// m-bootloader's installer.
    case mBootloader

    /// The destination in words, for the guide's text.
    var name: String {
        switch self {
        case .v15: "V15"
        case .v16: "V16"
        case .openFirmware: "M-VAVE's open firmware"
        case .feluccaPlatform: "another custom firmware"
        case .mBootloader: "m-bootloader"
        }
    }

    /// The bootloader installing it brings, for M-VAVE's firmwares.
    var bootArea: FM1BootArea? {
        switch self {
        case .v15: .v15
        case .v16: .v16
        case .openFirmware: .openFirmware
        case .feluccaPlatform, .mBootloader: nil
        }
    }
}

/// How to get from a firmware to a destination over USB-MIDI.
public enum LeavingRoute: String, Sendable, Hashable, Codable {
    /// Install it as usual.
    case direct
    /// The firmware refuses it: install a firmware with the fixed check first, such as
    /// MIDIMON 0.4, then the destination from that.
    case throughFixedFirmware
    /// Not known: try installing it, and if it's refused, go through a firmware with the fixed
    /// check.
    case uncertain
}

/// How to switch away from a firmware once it's installed, worked out from its package before
/// installing it.
///
/// Make one when the person picks a firmware, show ``warnings`` before installing it, and save
/// it with the FM-1 once it's installed: it's `Codable`. When they want to switch away, show
/// ``instructions(to:)``. A saved guide also tells firmwares that report another's identity
/// apart: TransitFM1 reports V15's.
///
/// Routes over V16's bootloader are expected from how each update check works, and haven't all
/// been tried on an FM-1. Installs in the chip's USB download mode, from a Mac, work whatever
/// firmware is running.
public struct LeavingGuide: Sendable, Hashable, Codable {
    /// The firmware's name, for the guide's text.
    public let firmwareName: String
    /// The identity the firmware reports, such as `FM-1_916`.
    public let identity: FM1Identity
    /// How it installs other firmwares.
    public let updateCode: UpdateCode
    /// The bootloader the FM-1 has once it's installed, or `nil` when that isn't known.
    public let bootArea: FM1BootArea?

    /// Works out how to switch away from `package` once it's installed, or fails for a package
    /// that isn't a firmware, such as m-bootloader's installer.
    ///
    /// Installing a package that brings M-VAVE's update loader writes its own bootloader, unless
    /// the firmware installing it uses a loader of its own. Other packages keep the bootloader the
    /// FM-1 has.
    ///
    /// - Parameters:
    ///   - package: The firmware about to be installed.
    ///   - name: Its name, such as "Felucca 1.6.1"; the package's identity if `nil`.
    ///   - bootArea: The bootloader the FM-1 has now, or `nil` if it isn't known.
    ///   - installedBy: How the firmware installing it installs others, from its saved guide, or
    ///     `nil` if that isn't known.
    public init?(
        package: FwscPackage,
        name: String? = nil,
        bootArea: FM1BootArea?,
        installedBy: UpdateCode? = nil
    ) {
        guard let updateCode = package.updateCode else { return nil }
        let writesBootArea = package.loaderSHA256 == OfficialFirmware.stockLoaderSHA256 && installedBy != .ownLoader
        self.init(
            firmwareName: name ?? package.identity.text,
            identity: package.identity,
            updateCode: updateCode,
            bootArea: writesBootArea ? package.bootAreaBrought : bootArea
        )
    }

    /// Makes a guide from what's known about a firmware.
    ///
    /// - Parameters:
    ///   - firmwareName: The firmware's name.
    ///   - identity: The identity it reports.
    ///   - updateCode: How it installs other firmwares.
    ///   - bootArea: The bootloader the FM-1 has with it installed, or `nil` if it isn't known.
    public init(firmwareName: String, identity: FM1Identity, updateCode: UpdateCode, bootArea: FM1BootArea?) {
        self.firmwareName = firmwareName
        self.identity = identity
        self.updateCode = updateCode
        self.bootArea = bootArea
    }

    /// How to get from this firmware to `destination` over USB-MIDI.
    public func route(to destination: LeavingDestination) -> LeavingRoute {
        switch updateCode {
        case .mVave:
            return destination == .mBootloader && identity != .officialV15 ? .uncertain : .direct
        case .feluccaFixedCheck:
            return .direct
        case .feluccaOriginalCheck:
            return routeByBootArea(to: destination)
        case .recognisesV15:
            return destination == .v15 ? .direct : routeByBootArea(to: destination)
        case .ownLoader:
            switch destination {
            case .v15, .feluccaPlatform: return .direct
            case .v16, .openFirmware: return .throughFixedFirmware
            case .mBootloader: return .uncertain
            }
        case .unknown:
            return .uncertain
        }
    }

    /// What the person should know before installing this firmware, such as that going back to
    /// V15 will take two installs.
    public var warnings: [String] {
        var warnings: [String] = []
        let refused = [LeavingDestination.v15, .v16].filter { route(to: $0) == .throughFixedFirmware }
        if !refused.isEmpty {
            let names = refused.map(\.name).joined(separator: " or ")
            warnings.append(
                "Once \(firmwareName) is installed, it can't install \(names) straight away. Going back takes "
                    + "two installs: \(Self.fixedFirmwares) first, then \(names). On a Mac, download mode "
                    + "can do it in one.")
        }
        if reportsOfficialIdentity {
            warnings.append(
                "\(firmwareName) reports itself as V15, so apps can't tell them apart. When switching away, "
                    + "say the FM-1 isn't really running V15.")
        }
        return warnings
    }

    /// Step-by-step instructions for switching from this firmware to `destination`.
    public func instructions(to destination: LeavingDestination) -> [String] {
        let name = destination.name
        var steps: [String]
        switch route(to: destination) {
        case .direct:
            steps = ["\(firmwareName) can install \(name) directly: install it as usual."]
        case .throughFixedFirmware:
            steps = [
                "\(firmwareName) can't install \(name) directly\(refusalReason(for: destination)).",
                "Install \(Self.fixedFirmwares) first: \(firmwareName) can install it.",
                "Then install \(name) from that.",
            ]
        case .uncertain:
            steps = [
                "Try installing \(name). It isn't known yet whether \(firmwareName) takes it.",
                "If it's refused, nothing changes: install \(Self.fixedFirmwares) first, then \(name) from that.",
            ]
        }
        if reportsOfficialIdentity, destination == .v15 {
            steps.append("\(firmwareName) reports itself as V15: confirm it isn't really V15 when asked.")
        }
        if updateCode == .ownLoader, destination.bootArea != nil, route(to: destination) == .direct {
            steps.append(
                "\(firmwareName) installs with its own loader, so the FM-1 keeps the bootloader it has, "
                    + "rather than getting \(name)'s.")
        }
        steps.append("On a Mac, installing \(name) in download mode works whatever firmware is running.")
        return steps
    }

    /// The firmware with the fixed check to suggest.
    ///
    /// LOOM-8 has it too, but from 0.8 its sounds need files that only its own installer sends,
    /// so it would sound broken installed alone.
    static let fixedFirmwares = "MIDIMON 0.4"

    /// True when the firmware reports the official firmware's identity without being it.
    private var reportsOfficialIdentity: Bool {
        identity.isOfficial && updateCode != .mVave
    }

    /// What Felucca's original check does: it takes M-VAVE's firmwares only onto the bootloader
    /// they bring.
    ///
    /// Felucca 1.6.1 and firmwares based on it also refuse open firmware and V16 at
    /// the header, whichever bootloader the FM-1 has, so those aren't certain even then.
    private func routeByBootArea(to destination: LeavingDestination) -> LeavingRoute {
        switch destination {
        case .feluccaPlatform: return .direct
        case .mBootloader: return .throughFixedFirmware
        case .v15, .v16, .openFirmware:
            guard let bootArea, bootArea == destination.bootArea else {
                return bootArea == nil ? .uncertain : .throughFixedFirmware
            }
            return destination == .v15 ? .direct : .uncertain
        }
    }

    /// Why this firmware refuses `destination`, after "can't install it directly".
    private func refusalReason(for destination: LeavingDestination) -> String {
        if destination == .mBootloader { return ": its update check only takes firmwares" }
        if updateCode == .ownLoader { return ": it only takes firmware images the size of V15's" }
        // Felucca 1.6.1 refuses these at the header, before comparing bootloaders.
        guard destination == .v15, let bootArea, bootArea != destination.bootArea else { return "" }
        let current =
            switch bootArea {
            case .v15: "V15's bootloader"
            case .v16: "V16's bootloader"
            case .openFirmware: "M-VAVE's open firmware's bootloader"
            case .mBootloader: "m-bootloader"
            }
        return ": its update check refuses it while the FM-1 has \(current)"
    }
}

extension FwscPackage {
    /// How the firmware installs other firmwares once it's running, read from its code, or `nil`
    /// for a package that isn't a firmware.
    ///
    /// See ``refusesV15OverOtherBootloaders`` for how each kind is recognised.
    public var updateCode: UpdateCode? {
        guard isFirmware else { return nil }
        guard let code = firmwareCode, code.contains(Self.feluccaLoaderMarker) else {
            return identity.isOfficial || identity.isOpenFirmware ? .mVave : .unknown
        }
        if code.contains(Self.bootloaderCheckMarker) { return .feluccaFixedCheck }
        if code.contains(Self.ownLoaderMarker) { return .ownLoader }
        return code.contains(Self.v15FlashImageSHA256) ? .recognisesV15 : .feluccaOriginalCheck
    }

    /// The bootloader the package brings, for M-VAVE's firmwares.
    var bootAreaBrought: FM1BootArea? {
        switch identity {
        case .officialV15: .v15
        case .officialV16: .v16
        default: identity.isOpenFirmware ? .openFirmware : nil
        }
    }
}
