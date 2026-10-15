/// Timings for an update session.
///
/// The standard values follow the FM-1-RE protocol notes and the vendor updater's behaviour.
/// They haven't yet been tuned against a wide range of hardware, so they're adjustable.
public struct UpdaterTiming: Sendable, Hashable {
    /// Pause after an upgrade command before the device starts asking for data.
    public var afterUpgradeCommand: Duration = .seconds(2)
    /// Give up staging when the device has been silent this long.
    public var stagingIdleLimit: Duration = .seconds(8)
    /// Pause after staging while the device reboots into the loader.
    public var loaderBoot: Duration = .seconds(3)
    /// How long to look for the loader after staging.
    public var loaderSearch: Duration = .seconds(30)
    /// Give up writing when the loader has been silent this long.
    public var writeIdleLimit: Duration = .seconds(60)
    /// Pause after writing while the device reboots into the new firmware.
    public var firmwareBoot: Duration = .seconds(3)
    /// How long to look for the device after writing.
    public var returnSearch: Duration = .seconds(40)
    /// Pause before each response, giving the device time between packets.
    public var responseDelay: Duration = .milliseconds(10)
    /// Time between port scans while waiting for a device.
    public var scanInterval: Duration = .seconds(1)
    /// How long to wait for a handshake reply.
    public var handshakeWait: Duration = .seconds(1)
    /// Handshake attempts per port.
    public var handshakeAttempts = 2

    /// Creates the standard timings, ready to adjust.
    public init() {}

    /// The standard timings.
    public static let standard = Self()
}
