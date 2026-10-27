/// A device found on a port, with its connection still open.
public struct FoundDevice: Sendable {
    /// The open connection, which the caller must close when finished with the device.
    public let connection: any MIDIConnection
    /// What the device said it is.
    public let identity: FM1Identity
    /// The port it was found on, as the transport listed it.
    let port: MIDIPortDescriptor
}

// MARK: - Discovery.

extension FM1Updater {
    /// The ports to probe, leaving out the other devices' when the updater works with one.
    ///
    /// Those are the ports that look like an FM-1's, apart from the ports of the devices listed
    /// alongside ``device``. Those keep their port while connected; this device comes back on a
    /// new one after restarting, which is told from theirs by serial number when it has one.
    func probeablePorts() async -> [MIDIPortDescriptor] {
        let ports = await transport.ports().filter(Self.isProbeable)
        guard let device else { return ports }
        let otherIDs = Set(device.otherPorts.map(\.id))
        // A serial number the chosen device shares can't tell the others from it.
        let otherSerials = Set(device.otherPorts.compactMap(\.serialNumber))
            .subtracting([device.serialNumber].compactMap(\.self))
        return ports.filter { port in
            !otherIDs.contains(port.id) && !otherSerials.contains(port.serialNumber ?? "")
        }
    }

    /// Finds the first probeable port whose device answers the handshake.
    ///
    /// Installs and resumes use ``findAll(where:)`` instead, and refuse to start when more than
    /// one device answers.
    ///
    /// - Parameter filter: Which identities to accept; any by default.
    /// - Returns: The device with its connection left open, or `nil` if none answered.
    public func find(where filter: @Sendable (FM1Identity) -> Bool = { _ in true }) async -> FoundDevice? {
        for port in await probeablePorts() {
            guard let connection = try? await transport.open(port) else { continue }
            if let identity = await handshake(connection), filter(identity) {
                return FoundDevice(connection: connection, identity: identity, port: port)
            }
            connection.close()
        }
        return nil
    }

    /// Finds every probeable port whose device answers the handshake.
    ///
    /// - Parameter filter: Which identities to accept; any by default.
    /// - Returns: The devices with their connections left open; the caller must close them all.
    public func findAll(where filter: @Sendable (FM1Identity) -> Bool = { _ in true }) async -> [FoundDevice] {
        var found: [FoundDevice] = []
        for port in await probeablePorts() {
            guard let connection = try? await transport.open(port) else { continue }
            if let identity = await handshake(connection), filter(identity) {
                found.append(FoundDevice(connection: connection, identity: identity, port: port))
            } else {
                connection.close()
            }
        }
        return found
    }

    /// Finds the only device matching `filter`.
    ///
    /// - Returns: The device with its connection left open, or `nil` if none answered.
    /// - Throws: ``FM1UpdateError/multipleDevices(count:)`` when more than one answered.
    func findOnly(where filter: @Sendable (FM1Identity) -> Bool) async throws(FM1UpdateError) -> FoundDevice? {
        let found = await findAll(where: filter)
        guard found.count <= 1 else {
            for device in found {
                device.connection.close()
            }
            throw .multipleDevices(count: found.count)
        }
        return found.first
    }
}
