/// Messages of the FM-1 USB-MIDI update protocol, as documented in AL-255/FM-1-RE
/// (`docs/io/11-ota-protocol.md`).
///
/// Every update message is SysEx. The device drives the transfer: it sends read requests for
/// ranges of the logical firmware image, and the host answers each one with the bytes asked for.
///
/// Unpacked message layout (before 7-bit packing):
///
///     00 59 cmd | body_length:u24le | flash_type:u8 | address:u32le | length:u24le | data | checksum
///
/// `body_length` is 8 plus the data length, and the checksum is `~sum(flash_type ... data) & 0xFF`.
public enum FM1Message {
    /// Asks the running firmware (or the update loader) who it is.
    public static let handshakeQuery: [UInt8] = [0xF0, 0x00, 0x32, 0x45, 0x00, 0x00, 0x00, 0x40, 0x7F, 0xF7]

    /// Starts an update session. Sent once to the firmware (staging) and once to the loader (writing).
    public static let upgradeCommand: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7F, 0xF7]

    /// The device asks for this address when staging has finished and it is about to reboot into the loader.
    public static let stageFinishAddress: UInt32 = 0xE000_0000

    /// The loader asks for this address when the write has finished and it is about to reboot.
    public static let writeFinishAddress: UInt32 = 0xF000_0000

    /// The reply to either finish address.
    public static let finishPayload: [UInt8] = Array("success".utf8) + [0]

    /// The largest read the host will answer; anything bigger is treated as a protocol error.
    public static let maximumReadLength = 512

    static let prefix: [UInt8] = [0x00, 0x59]
    static let readCommand: UInt8 = 0x30
    static let identityCommand: UInt8 = 0x11
    static let fixedFieldsLength = 8
    static let headerLength = 6

    /// Wraps an unpacked message body in `F0 ... F7` after 7-bit packing.
    static func frame(_ unpacked: [UInt8]) -> [UInt8] {
        [0xF0] + SevenBit.pack(unpacked) + [0xF7]
    }

    /// Strips `F0 ... F7` and unpacks; `nil` when the bytes are not a complete SysEx message.
    static func unframe(_ sysex: [UInt8]) -> [UInt8]? {
        guard sysex.count >= 2, sysex.first == 0xF0, sysex.last == 0xF7 else {
            return nil
        }
        return SevenBit.unpack(sysex.dropFirst().dropLast())
    }

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        ~UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) })
    }

    static func header(command: UInt8, bodyLength: Int) -> [UInt8] {
        prefix + [command] + littleEndian(UInt32(bodyLength), byteCount: 3)
    }

    static func littleEndian(_ value: UInt32, byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    static func readLittleEndian(_ bytes: [UInt8], at offset: Int, byteCount: Int) -> UInt32 {
        (0..<byteCount).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}

/// A read request from the device: "send me `length` bytes of the image at `address`".
public struct FM1ReadRequest: Equatable, Sendable {
    /// Which flash the device is reading; 0 for the firmware image.
    public var flashType: UInt8
    /// Where in the logical image to read from, or a finish address.
    public var address: UInt32
    /// How many bytes to send back.
    public var length: Int

    /// Makes a request, as the simulated device does.
    public init(flashType: UInt8 = 0, address: UInt32, length: Int) {
        self.flashType = flashType
        self.address = address
        self.length = length
    }

    /// Parses a request; `nil` for any other message, or one whose checksum does not match.
    public init?(sysex: [UInt8]) {
        guard
            let body = FM1Message.unframe(sysex),
            body.count == FM1Message.headerLength + FM1Message.fixedFieldsLength + 1,
            Array(body[0..<2]) == FM1Message.prefix,
            body[2] == FM1Message.readCommand,
            FM1Message.checksum(body[6..<14]) == body[14]
        else {
            return nil
        }
        flashType = body[6]
        address = FM1Message.readLittleEndian(body, at: 7, byteCount: 4)
        length = Int(FM1Message.readLittleEndian(body, at: 11, byteCount: 3))
    }

    /// True for the two magic addresses that end a phase rather than read image data.
    public var isFinish: Bool {
        address == FM1Message.stageFinishAddress || address == FM1Message.writeFinishAddress
    }

    /// The request as the device sends it (used by the simulated device and the tests).
    public func encoded() -> [UInt8] {
        FM1Message.frame(Self.body(command: FM1Message.readCommand, flashType: flashType, address: address, length: length, data: []))
    }

    /// The host's answer to this request carrying `data`.
    public func response(with data: some Collection<UInt8>) -> [UInt8] {
        FM1Message.frame(Self.body(command: FM1Message.readCommand, flashType: flashType, address: address, length: data.count, data: Array(data)))
    }

    /// The host's answer to a finish request.
    public func finishResponse() -> [UInt8] {
        response(with: FM1Message.finishPayload)
    }

    /// Parses a host response into the request it answers and its data (used by the simulated device).
    public static func parseResponse(_ sysex: [UInt8]) -> (request: FM1ReadRequest, data: [UInt8])? {
        guard
            let body = FM1Message.unframe(sysex),
            body.count >= FM1Message.headerLength + FM1Message.fixedFieldsLength + 1,
            Array(body[0..<2]) == FM1Message.prefix,
            body[2] == FM1Message.readCommand
        else {
            return nil
        }
        let bodyLength = Int(FM1Message.readLittleEndian(body, at: 3, byteCount: 3))
        let length = Int(FM1Message.readLittleEndian(body, at: 11, byteCount: 3))
        let checksumIndex = 14 + length
        guard
            bodyLength == length + FM1Message.fixedFieldsLength,
            body.count == checksumIndex + 1,
            FM1Message.checksum(body[6..<checksumIndex]) == body[checksumIndex]
        else {
            return nil
        }
        let request = FM1ReadRequest(
            flashType: body[6],
            address: FM1Message.readLittleEndian(body, at: 7, byteCount: 4),
            length: length
        )
        return (request, Array(body[14..<checksumIndex]))
    }

    private static func body(command: UInt8, flashType: UInt8, address: UInt32, length: Int, data: [UInt8]) -> [UInt8] {
        var body = FM1Message.header(command: command, bodyLength: data.count + FM1Message.fixedFieldsLength)
        body.append(flashType)
        body += FM1Message.littleEndian(address, byteCount: 4)
        body += FM1Message.littleEndian(UInt32(length), byteCount: 3)
        body += data
        body.append(FM1Message.checksum(body[6...]))
        return body
    }
}
