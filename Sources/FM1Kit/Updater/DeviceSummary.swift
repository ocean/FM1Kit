/// What's connected, in the terms a person would use: which firmware it's running, whether it's
/// waiting part-way through an update, and which FM-1 it is.
public struct FM1DeviceSummary: Sendable, Hashable {
    /// What the FM-1 reports.
    public let identity: FM1Identity
    /// The name of the port it's on, such as `FM-1` or `Felucca`.
    public let portName: String
    /// The FM-1's USB serial number, when its firmware reports one.
    ///
    /// M-VAVE's V15 and open firmware report the same number for a unit, so an app can remember
    /// things about it, such as its colourway; Felucca reports none.
    public let serialNumber: String?

    /// True when the FM-1 is in its update loader rather than running firmware: an update was
    /// cut off, or it was started in USB recovery mode. ``FM1Updater/resume(_:events:)``
    /// finishes it.
    public var isWaitingMidUpdate: Bool { identity.isLoader }

    /// The firmware's name, for the firmwares FM1Kit knows: "M-VAVE V15" or "M-VAVE open
    /// firmware". `nil` for others, which apps can name from their own catalogue by
    /// ``identity``, and while ``isWaitingMidUpdate``.
    public var firmwareName: String? {
        if identity == .officialV15 { return "M-VAVE V15" }
        return identity.isOpenFirmware ? "M-VAVE open firmware" : nil
    }

    /// The firmware's version, for the firmwares FM1Kit knows: "15" for V15, "12" for open
    /// firmware V12. `nil` whenever ``firmwareName`` is.
    public var firmwareVersion: String? {
        if identity == .officialV15 { return "15" }
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
    public init(identity: FM1Identity, portName: String, serialNumber: String?) {
        self.identity = identity
        self.portName = portName
        self.serialNumber = serialNumber
    }
}

extension FM1Updater {
    /// Describes the connected FM-1, without changing it.
    ///
    /// Only the handshake query is sent.
    ///
    /// - Returns: The FM-1, or `nil` if none answered.
    /// - Throws: ``FM1UpdateError/multipleDevices(count:)`` when more than one FM-1 answered.
    public func summary() async throws(FM1UpdateError) -> FM1DeviceSummary? {
        guard let device = try await findOnly(where: { _ in true }) else { return nil }
        device.connection.close()
        let port = device.connection.port
        return FM1DeviceSummary(identity: device.identity, portName: port.name, serialNumber: port.serialNumber)
    }
}
