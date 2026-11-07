/// What's connected, in the terms a person would use: which firmware it's running, whether it's
/// waiting part-way through an update, and which FM-1 it is.
///
/// ``FM1Updater/devices()`` lists every device connected, so a person can choose one when
/// there's more than one; ``FM1Updater/init(transport:timing:device:)`` then works with it alone.
public struct FM1DeviceSummary: Sendable, Hashable, Identifiable {
    /// What the FM-1 reports.
    public let identity: FM1Identity
    /// The port it answered on.
    public let port: MIDIPortDescriptor
    /// The flash chip's JEDEC ID, such as ``FM1FlashChip/uc25hq80``, when the firmware reports
    /// it, as firmwares built on felucca-bsp since November 2026 do; `nil` otherwise.
    public let flashChipID: UInt32?
    /// The ports the other devices answered on when this one was found, which an updater
    /// working with this device leaves alone.
    let otherPorts: [MIDIPortDescriptor]

    /// The port's identifier, which tells devices apart while they stay connected.
    public var id: String { port.id }
    /// The name of the port it's on, such as `FM-1` or `Felucca`.
    public var portName: String { port.name }
    /// The FM-1's USB serial number, when its firmware reports one.
    ///
    /// M-VAVE's V15 and open firmware report the same number for a unit, so an app can remember
    /// things about it, such as its colourway; Felucca reports none.
    public var serialNumber: String? { port.serialNumber }

    /// True when the FM-1 is in its update loader rather than running firmware: an update was
    /// cut off, or it was started in USB recovery mode. ``FM1Updater/resume(_:events:)``
    /// finishes it.
    public var isWaitingMidUpdate: Bool { identity.isLoader }

    /// True when the firmware reports the newer flash chip, the UC25HQ80.
    ///
    /// FM-1s sold since autumn 2026 have it, and firmwares that don't know it keep saves on it
    /// only until switched off. When the firmware doesn't report a chip, this is false, which
    /// doesn't mean the FM-1 has the first chip.
    public var hasNewerFlashChip: Bool { flashChipID == FM1FlashChip.uc25hq80 }

    /// The firmware's name, for the firmwares FM1Kit knows: "M-VAVE V15", "M-VAVE V16" or "M-VAVE open
    /// firmware". `nil` for others, which apps can name from their own catalogue by
    /// ``identity``, and while ``isWaitingMidUpdate``.
    public var firmwareName: String? {
        if identity == .officialV15 { return "M-VAVE V15" }
        if identity == .officialV16 { return "M-VAVE V16" }
        return identity.isOpenFirmware ? "M-VAVE open firmware" : nil
    }

    /// The firmware's version, for the firmwares FM1Kit knows: "15" for V15, "16" for V16, "12" for open
    /// firmware V12. `nil` whenever ``firmwareName`` is.
    public var firmwareVersion: String? {
        if identity == .officialV15 { return "15" }
        if identity == .officialV16 { return "16" }
        guard identity.isOpenFirmware else { return nil }
        return identity.model == "FM-1"
            ? String(identity.version - FM1Identity.openVersions.lowerBound) : String(identity.version)
    }

    /// Describes a device.
    ///
    /// - Parameters:
    ///   - identity: What the FM-1 reports.
    ///   - portName: The name of the port it's on.
    ///   - serialNumber: Its USB serial number, if it reports one.
    ///   - flashChipID: The flash chip its firmware reports, if any.
    public init(identity: FM1Identity, portName: String, serialNumber: String?, flashChipID: UInt32? = nil) {
        let port = MIDIPortDescriptor(id: "", name: portName, serialNumber: serialNumber)
        self.init(identity: identity, port: port, flashChipID: flashChipID)
    }

    /// Describes a device on a port.
    ///
    /// - Parameters:
    ///   - identity: What the FM-1 reports.
    ///   - port: The port it answered on.
    ///   - flashChipID: The flash chip its firmware reports, if any.
    public init(identity: FM1Identity, port: MIDIPortDescriptor, flashChipID: UInt32? = nil) {
        self.init(identity: identity, port: port, flashChipID: flashChipID, otherPorts: [])
    }

    init(identity: FM1Identity, port: MIDIPortDescriptor, flashChipID: UInt32?, otherPorts: [MIDIPortDescriptor]) {
        self.identity = identity
        self.port = port
        self.flashChipID = flashChipID
        self.otherPorts = otherPorts
    }
}

extension FM1Updater {
    /// Describes the connected FM-1, without changing it.
    ///
    /// Only the handshake query is sent, and the query for the full identity when the answer may
    /// have left something out.
    ///
    /// - Returns: The FM-1, or `nil` if none answered.
    /// - Throws: ``FM1UpdateError/multipleDevices(count:)`` when more than one FM-1 answered.
    public func summary() async throws(FM1UpdateError) -> FM1DeviceSummary? {
        guard let device = try await findOnly(where: { _ in true }) else { return nil }
        device.connection.close()
        return FM1DeviceSummary(identity: device.identity, port: device.port, flashChipID: device.flashChipID)
    }

    /// Lists every device connected, without changing any of them.
    ///
    /// Only the handshake query is sent, to each port whose name looks like an FM-1's, and the query
    /// for the full identity when an answer may have left something out. More than
    /// one FM-1 can be connected, and other M-VAVE devices may answer too: ``FM1DeviceSummary/identity``
    /// says which model each is. Let the person choose one, then make an updater that works with
    /// it alone (``init(transport:timing:device:)``). An updater that already works with one
    /// device lists only that one.
    ///
    /// - Returns: The devices that answered, in the order the system lists their ports.
    public func devices() async -> [FM1DeviceSummary] {
        let found = await findAll()
        for device in found {
            device.connection.close()
        }
        let ports = found.map(\.port)
        return found.map { device in
            FM1DeviceSummary(
                identity: device.identity,
                port: device.port,
                flashChipID: device.flashChipID,
                otherPorts: ports.filter { $0 != device.port }
            )
        }
    }
}
