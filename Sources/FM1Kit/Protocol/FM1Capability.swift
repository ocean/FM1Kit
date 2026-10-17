/// A firmware build's 32-byte identifier, which M-VAVE's open firmware reports and is armed with.
///
/// Open firmware builds carry a hash of their sources. M-VAVE's updater uses the package file's
/// SHA-256 as the build ID of firmwares that don't carry one, such as V15.
public struct FM1BuildID: Hashable, Sendable, CustomStringConvertible {
    /// The identifier's length in bytes.
    public static let byteCount = 32

    /// The identifier's bytes.
    public let bytes: [UInt8]

    /// Reads a build ID written as hex.
    ///
    /// Fails unless the text is exactly 64 hex digits (either case).
    ///
    /// - Parameter hex: The build ID, e.g. from a firmware's release notes or manifest.
    public init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count == Self.byteCount * 2 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.byteCount)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let high = Self.nibble(digits[index]), let low = Self.nibble(digits[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.bytes = bytes
    }

    /// Makes a build ID from its bytes; there must be ``byteCount`` of them.
    init(bytes: some Collection<UInt8>) {
        precondition(bytes.count == Self.byteCount, "A build ID is 32 bytes.")
        self.bytes = Array(bytes)
    }

    /// Makes a build ID from hex known to be valid, such as a SHA-256 FM1Kit computed.
    init(knownHex hex: String) {
        guard let id = Self(hex: hex) else { preconditionFailure("\(hex) isn't a build ID.") }
        self = id
    }

    /// The build ID as 64 lower-case hex digits.
    public var hex: String {
        bytes.map { String(UInt8($0 >> 4), radix: 16) + String(UInt8($0 & 0xF), radix: 16) }.joined()
    }

    /// The build ID as 64 lower-case hex digits.
    public var description: String { hex }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// What M-VAVE's open firmware reports about its update support.
///
/// Open firmware answers a capability query (command `0x31`) with this, and must be armed
/// (command `0x32`) with the incoming package's length and build ID before the upgrade command.
/// Firmwares without the open firmware's update support, such as V15 and Felucca, don't answer.
/// The layout follows M-VAVE's open-source updater (<https://github.com/m-vave/fm1_open>).
public struct FM1Capability: Hashable, Sendable {
    /// The update family every FM-1 reports.
    public static let fm1Family = 7

    /// The update family: ``fm1Family`` for an FM-1.
    public let family: Int
    /// What the firmware's updater is doing: 0 when it's ready for an update.
    public let state: Int
    /// The running build's identifier.
    public let buildID: FM1BuildID
    /// The updater's last error code, or 0.
    public let errorCode: Int

    /// Makes a capability, as a simulated device reports it.
    ///
    /// - Parameters:
    ///   - family: The update family, 0 to 7.
    ///   - state: 0 when ready for an update.
    ///   - buildID: The running build's identifier.
    ///   - errorCode: The updater's last error code.
    public init(family: Int = Self.fm1Family, state: Int = 0, buildID: FM1BuildID, errorCode: Int = 0) {
        precondition((0...Self.maximumFamily).contains(family), "An update family is 0 to 7.")
        self.family = family
        self.state = state
        self.buildID = buildID
        self.errorCode = errorCode
    }

    /// Parses the payload of a capability reply.
    ///
    /// Fails unless it's the 47-byte `FMC1` layout, version 1, for M-VAVE's loader, with 512-byte
    /// reads and 1 MB of flash, as M-VAVE's updater requires.
    ///
    /// - Parameter payload: The reply's payload, after unpacking.
    public init?(payload: [UInt8]) {
        guard
            payload.count == Self.payloadLength,
            payload.starts(with: Self.magic),
            payload[4] == Self.version,
            Int(payload[5]) <= Self.maximumFamily,
            payload[7] == Self.loaderKind,
            FM1Message.readLittleEndian(payload, at: 8, byteCount: 2) == UInt32(FM1Message.maximumReadLength),
            FM1Message.readLittleEndian(payload, at: 10, byteCount: 4) == Self.flashLength
        else {
            return nil
        }
        family = Int(payload[5])
        state = Int(payload[6])
        buildID = FM1BuildID(bytes: payload[14..<46])
        errorCode = Int(payload[46])
    }

    /// True when the firmware is ready to start an update.
    public var isReady: Bool { state == 0 }

    /// The reply's payload, as the device sends it.
    public func payload() -> [UInt8] {
        var payload = Self.magic + [Self.version, UInt8(family), UInt8(truncatingIfNeeded: state), Self.loaderKind]
        payload += FM1Message.littleEndian(UInt32(FM1Message.maximumReadLength), byteCount: 2)
        payload += FM1Message.littleEndian(Self.flashLength, byteCount: 4)
        payload += buildID.bytes + [UInt8(truncatingIfNeeded: errorCode)]
        return payload
    }

    /// The arming request's payload: version, family, the logical image's length and the build ID.
    static func armPayload(family: Int, imageLength: Int, buildID: FM1BuildID) -> [UInt8] {
        [1, UInt8(family)] + FM1Message.littleEndian(UInt32(imageLength), byteCount: 4) + buildID.bytes
    }

    /// The reply that accepts an arming request.
    static let armAccepted: [UInt8] = [0]

    static let payloadLength = 47
    static let magic = Array("FMC1".utf8)
    static let version: UInt8 = 1
    static let maximumFamily = 7
    /// M-VAVE's loader; the only kind the protocol knows.
    static let loaderKind: UInt8 = 1
    static let flashLength: UInt32 = 1_048_576
}
