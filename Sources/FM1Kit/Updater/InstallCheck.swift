/// What installing a package would do to the connected FM-1.
public enum InstallKind: Sendable, Hashable {
    /// A different build of the open firmware the FM-1 is running.
    case update
    /// A different firmware from the one running: between V15, M-VAVE's open firmware and custom
    /// firmwares, or between two custom firmwares, which FM1Kit can't tell apart. M-VAVE's updater
    /// calls this force flashing: it can erase the FM-1's projects and samples, so warn first and
    /// confirm with ``InstallOptions/confirmsSwitchingFirmware``.
    case switchingFirmware
    /// The firmware already running, which isn't reinstalled: V15 is believed to refuse its own
    /// identity, and open firmware is already running this build. M-VAVE's official firmware over
    /// an FM-1 reporting its identity can be installed with ``InstallOptions/confirmsReinstallingOfficial``
    /// (``InstallCheck/canReinstallOfficial``).
    case reinstall
    /// A package with the identity a custom firmware is reporting: a reinstall, or another release
    /// of a firmware that keeps one identity across releases (as Felucca-derived firmwares can).
    /// FM1Kit can't tell which, nor rule out a different firmware sharing the number, so confirm
    /// it with ``InstallOptions/confirmsSameIdentity``.
    case sameIdentity
}

/// The connected FM-1 and what installing a package on it would do, from
/// ``FM1Updater/check(_:buildID:)``.
public struct InstallCheck: Sendable, Hashable {
    /// What the FM-1 is running.
    public let device: FM1Identity
    /// What its open firmware reports about its update support, or `nil` for other firmwares.
    public let capability: FM1Capability?
    /// What the install would do.
    public let kind: InstallKind

    /// Decides what installing `package` on a device would do.
    ///
    /// - Parameters:
    ///   - device: What the device reports.
    ///   - capability: What its open firmware reports, if it's running open firmware.
    ///   - package: The package to install.
    ///   - buildID: The package's build ID, when known.
    init(device: FM1Identity, capability: FM1Capability?, package: FwscPackage, buildID: FM1BuildID?) {
        self.device = device
        self.capability = capability
        if let capability {
            let isSameBuild = buildID == capability.buildID
            let isSameLine = package.identity.isOpenFirmware && capability.family == FM1Capability.fm1Family
            kind = isSameBuild ? .reinstall : isSameLine ? .update : .switchingFirmware
        } else if device == package.identity {
            kind = device == .officialV15 ? .reinstall : .sameIdentity
        } else {
            kind = .switchingFirmware
        }
    }

    /// True when the FM-1 reports the identity of M-VAVE's official firmware (V15) and the
    /// package has it too, so the install is a
    /// ``InstallKind/reinstall`` that ``InstallOptions/confirmsReinstallingOfficial`` allows.
    ///
    /// Some firmwares report the official firmware's identity on purpose, so that every
    /// installer treats them as it: TransitFM1 does. Offer this when the person says the FM-1
    /// isn't really running the official firmware.
    public var canReinstallOfficial: Bool {
        kind == .reinstall && capability == nil
    }
}

/// Choices for ``FM1Updater/install(_:options:events:)``.
public struct InstallOptions: Sendable, Hashable {
    /// Allows an install of kind ``InstallKind/switchingFirmware``.
    ///
    /// Switching firmware can erase the FM-1's projects and samples. Set this only once the person
    /// updating has been warned and has backed them up.
    public var confirmsSwitchingFirmware = false

    /// Allows an install of kind ``InstallKind/sameIdentity``.
    ///
    /// Set this once the person updating has confirmed they mean to reinstall, or update to
    /// another release of the same firmware.
    public var confirmsSameIdentity = false

    /// Allows installing M-VAVE's official firmware (V15) on an FM-1 that reports its identity
    /// (``InstallCheck/canReinstallOfficial``).
    ///
    /// Set this once the person updating has confirmed the FM-1 is running a firmware that
    /// reports the official firmware's identity, such as TransitFM1, rather than the official
    /// firmware itself. V15 is believed to refuse its own identity, which would stop the install
    /// while staging, leaving it as it was.
    public var confirmsReinstallingOfficial = false

    /// The package's build ID, for arming open firmware and checking the build it reports after
    /// the update.
    ///
    /// FM1Kit knows the build IDs of ``OfficialFirmware/known``. For other packages, pass the ID
    /// their publisher gives; without one, open firmware is armed with the package file's
    /// SHA-256, as M-VAVE's updater does for firmwares without their own ID.
    public var buildID: FM1BuildID?

    /// Makes options.
    ///
    /// - Parameters:
    ///   - confirmsSwitchingFirmware: Allow switching to a different firmware.
    ///   - confirmsSameIdentity: Allow installing the identity a custom firmware is reporting.
    ///   - confirmsReinstallingOfficial: Allow installing the official firmware on an FM-1 that
    ///     reports its identity.
    ///   - buildID: The package's build ID, if known.
    public init(
        confirmsSwitchingFirmware: Bool = false,
        confirmsSameIdentity: Bool = false,
        confirmsReinstallingOfficial: Bool = false,
        buildID: FM1BuildID? = nil
    ) {
        self.confirmsSwitchingFirmware = confirmsSwitchingFirmware
        self.confirmsSameIdentity = confirmsSameIdentity
        self.confirmsReinstallingOfficial = confirmsReinstallingOfficial
        self.buildID = buildID
    }
}
