/// Timings for an update session.
///
/// The standard values follow the FM-1-RE protocol notes and M-VAVE's own browser updater, which
/// answers each read as soon as the device asks and adds no pauses. They haven't yet been tuned
/// against a wide range of hardware, so they're adjustable.
public struct UpdaterTiming: Sendable, Hashable {
    /// Pause after an upgrade command before answering the device's requests; none by default,
    /// as requests that arrive meanwhile wait in the connection.
    public var afterUpgradeCommand: Duration = .zero
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
    /// Pause before each response; none by default, as the device asks for each block only
    /// when it's ready for it.
    public var responseDelay: Duration = .zero
    /// How long to keep the connection open after answering a finish request, answering any
    /// repeat, before closing it.
    public var finishSettle: Duration = .milliseconds(600)
    /// Time between port scans while waiting for a device.
    public var scanInterval: Duration = .seconds(1)
    /// How long to wait for a handshake reply.
    public var handshakeWait: Duration = .seconds(1)
    /// How long to wait for open firmware to answer a capability query or an arming request.
    public var commandReplyWait: Duration = .milliseconds(1500)
    /// How long to wait for V15 to acknowledge each step of a voice restore.
    public var voiceReplyWait: Duration = .seconds(10)
    /// How long to wait for each reply from open firmware's project library before asking again.
    public var libraryReplyWait: Duration = .seconds(1)
    /// Handshake attempts per port.
    public var handshakeAttempts = 2

    /// Creates the standard timings, ready to adjust.
    public init() {}

    /// The standard timings.
    public static let standard = Self()
}
