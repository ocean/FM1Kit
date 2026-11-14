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
    /// Once nearly all of the application area has been read, how long the loader may stay silent
    /// before the updater looks for the new firmware, and then how often it looks again: some
    /// loaders restart without asking to finish.
    public var returnCheckAfter: Duration = .seconds(5)
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
    /// How long to wait for a firmware's first read after asking it to take resources, besides
    /// ``resourceSectorEraseWait`` for each 4 KB sector it erases first.
    public var resourceStartWait: Duration = .seconds(5)
    /// How long a firmware taking resources may spend erasing each 4 KB sector of the region.
    public var resourceSectorEraseWait: Duration = .milliseconds(300)
    /// How long to wait for a firmware's next read once it says it's asking a question on its
    /// screen; it waits up to a minute for an answer.
    public var resourceAskWait: Duration = .seconds(75)
    /// How long a firmware taking resources may go without reading before it counts as stopped.
    public var resourceIdleLimit: Duration = .seconds(10)
    /// How long to wait for each reply from open firmware's project library before asking again.
    public var libraryReplyWait: Duration = .seconds(1)
    /// Handshake attempts per port.
    public var handshakeAttempts = 2
    /// How long to wait for the whole identity after a reply that may be shortened or carried no
    /// flash chip, which M-VAVE's firmwares and those built before November 2026 never answer.
    public var fullIdentityWait: Duration = .milliseconds(300)

    /// Creates the standard timings, ready to adjust.
    public init() {}

    /// The standard timings.
    public static let standard = Self()
}
