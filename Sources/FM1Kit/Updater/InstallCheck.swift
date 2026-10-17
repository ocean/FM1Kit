/// What installing a package would do to the connected FM-1.
public enum InstallKind: Sendable, Hashable {
    /// A different build of the open firmware the FM-1 is running.
    case update
    /// A different firmware from the one running: between V15, M-VAVE's open firmware and custom
    /// firmwares, or between two custom firmwares, which FM1Kit can't tell apart. M-VAVE's updater
    /// calls this force flashing: it can erase the FM-1's projects and samples, so warn first and
    /// confirm with ``InstallOptions/confirmsSwitchingFirmware``.
    case switchingFirmware
    /// The firmware already running, which the FM-1 refuses to reinstall.
    case reinstall
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
        } else {
            kind = device == package.identity ? .reinstall : .switchingFirmware
        }
    }
}

/// Choices for ``FM1Updater/install(_:options:events:)``.
public struct InstallOptions: Sendable, Hashable {
    /// Allows an install of kind ``InstallKind/switchingFirmware``.
    ///
    /// Switching firmware can erase the FM-1's projects and samples. Set this only once the person
    /// updating has been warned and has backed them up.
    public var confirmsSwitchingFirmware = false

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
    ///   - buildID: The package's build ID, if known.
    public init(confirmsSwitchingFirmware: Bool = false, buildID: FM1BuildID? = nil) {
        self.confirmsSwitchingFirmware = confirmsSwitchingFirmware
        self.buildID = buildID
    }
}
