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

    /// Starts an update session.
    ///
    /// It's sent twice: once to the running firmware to start staging, then once to the update
    /// loader to start writing.
    public static let upgradeCommand: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7F, 0xF7]

    /// The address the device asks for when staging has finished and it's about to restart into its loader.
    public static let stageFinishAddress: UInt32 = 0xE000_0000

    /// The loader asks for this address when the write has finished and it is about to reboot.
    public static let writeFinishAddress: UInt32 = 0xF000_0000

    /// The reply to either finish address.
    public static let finishPayload: [UInt8] = Array("success".utf8) + [0]

    /// The largest read the host will answer; anything bigger is treated as a protocol error.
    public static let maximumReadLength = 512

    /// The two bytes that start every unpacked message.
    static let prefix: [UInt8] = [0x00, 0x59]
    /// The command for read requests and their responses.
    static let readCommand: UInt8 = 0x30
    /// The command the identity reply carries.
    static let identityCommand: UInt8 = 0x11
    /// Asks M-VAVE's open firmware about its update support; see ``FM1Capability``.
    static let capabilityCommand: UInt8 = 0x31
    /// Arms M-VAVE's open firmware for an update, before the upgrade command.
    static let armCommand: UInt8 = 0x32
    /// Flash type, address and length: the body fields before any data.
    static let fixedFieldsLength = 8
    /// Prefix, command and body length.
    static let headerLength = 6

    /// Byte offsets of the fields in an unpacked message.
    enum Offset {
        /// The command byte, after the two prefix bytes.
        static let command = 2
        /// The 24-bit little-endian body length.
        static let bodyLength = 3
        /// The flash type, where the checksummed body starts.
        static let flashType = 6
        /// The 32-bit little-endian address.
        static let address = 7
        /// The 24-bit little-endian requested length.
        static let length = 11
        /// The data in a response, or the checksum in a request.
        static let data = 14
    }

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

    /// The protocol's checksum: the complement of the bytes' sum, modulo 256.
    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        ~UInt8(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) })
    }

    /// Encodes a command with its payload: header, payload and the payload's checksum.
    static func command(_ command: UInt8, payload: [UInt8] = []) -> [UInt8] {
        frame(header(command: command, bodyLength: payload.count) + payload + [checksum(payload[...])])
    }

    /// Decodes any command; `nil` when the bytes aren't a complete, correctly checksummed message.
    static func parseCommand(_ sysex: [UInt8]) -> (command: UInt8, payload: [UInt8])? {
        guard
            let body = unframe(sysex),
            body.count > headerLength,
            body.starts(with: prefix),
            Int(readLittleEndian(body, at: Offset.bodyLength, byteCount: 3)) == body.count - headerLength - 1,
            checksum(body[headerLength..<(body.count - 1)]) == body[body.count - 1]
        else {
            return nil
        }
        return (body[Offset.command], Array(body[headerLength..<(body.count - 1)]))
    }

    /// The prefix, command and body length that start every message.
    static func header(command: UInt8, bodyLength: Int) -> [UInt8] {
        prefix + [command] + littleEndian(UInt32(bodyLength), byteCount: 3)
    }

    /// The low `byteCount` bytes of `value`, least significant first.
    static func littleEndian(_ value: UInt32, byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// Reads a little-endian number; the caller checks `bytes` is long enough.
    static func readLittleEndian(_ bytes: [UInt8], at offset: Int, byteCount: Int) -> UInt32 {
        (0..<byteCount).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}

/// A read request from the device, asking for `length` bytes of the image at `address`.
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

    /// Parses a request from the device.
    ///
    /// Fails for any other message, or a request whose checksum doesn't match.
    ///
    /// - Parameter sysex: A complete `F0 … F7` message.
    public init?(sysex: [UInt8]) {
        typealias Offset = FM1Message.Offset
        guard
            let body = FM1Message.unframe(sysex),
            body.count == FM1Message.headerLength + FM1Message.fixedFieldsLength + 1,
            body.starts(with: FM1Message.prefix),
            body[Offset.command] == FM1Message.readCommand,
            FM1Message.checksum(body[Offset.flashType..<Offset.data]) == body[Offset.data]
        else {
            return nil
        }
        flashType = body[Offset.flashType]
        address = FM1Message.readLittleEndian(body, at: Offset.address, byteCount: 4)
        length = Int(FM1Message.readLittleEndian(body, at: Offset.length, byteCount: 3))
    }

    /// True for the two magic addresses that end a phase rather than read image data.
    public var isFinish: Bool {
        address == FM1Message.stageFinishAddress || address == FM1Message.writeFinishAddress
    }

    /// Encodes the request as the device sends it, for simulated devices and tests.
    ///
    /// - Returns: A complete `F0 … F7` message.
    public func encoded() -> [UInt8] {
        FM1Message.frame(Self.body(flashType: flashType, address: address, length: length, data: []))
    }

    /// Encodes the host's answer to this request.
    ///
    /// The answer declares the length of `data`, which should be the requested ``length``.
    ///
    /// - Parameter data: The image bytes asked for.
    /// - Returns: A complete `F0 … F7` message.
    public func response(with data: some Collection<UInt8>) -> [UInt8] {
        FM1Message.frame(Self.body(flashType: flashType, address: address, length: data.count, data: Array(data)))
    }

    /// Encodes the host's answer to a finish request: `success` and a zero byte.
    ///
    /// - Returns: A complete `F0 … F7` message.
    public func finishResponse() -> [UInt8] {
        response(with: FM1Message.finishPayload)
    }

    /// Parses a host's answer, as a device does; used by simulated devices.
    ///
    /// - Parameter sysex: A complete `F0 … F7` message.
    /// - Returns: The request it answers and the data it carries, or `nil` for any other message,
    ///   or an answer whose declared length or checksum is wrong.
    public static func parseResponse(_ sysex: [UInt8]) -> (request: Self, data: [UInt8])? {
        typealias Offset = FM1Message.Offset
        guard
            let body = FM1Message.unframe(sysex),
            body.count >= FM1Message.headerLength + FM1Message.fixedFieldsLength + 1,
            body.starts(with: FM1Message.prefix),
            body[Offset.command] == FM1Message.readCommand
        else {
            return nil
        }
        let bodyLength = Int(FM1Message.readLittleEndian(body, at: Offset.bodyLength, byteCount: 3))
        let length = Int(FM1Message.readLittleEndian(body, at: Offset.length, byteCount: 3))
        let checksumIndex = Offset.data + length
        guard
            bodyLength == length + FM1Message.fixedFieldsLength,
            body.count == checksumIndex + 1,
            FM1Message.checksum(body[Offset.flashType..<checksumIndex]) == body[checksumIndex]
        else {
            return nil
        }
        let request = Self(
            flashType: body[Offset.flashType],
            address: FM1Message.readLittleEndian(body, at: Offset.address, byteCount: 4),
            length: length
        )
        return (request, Array(body[Offset.data..<checksumIndex]))
    }

    /// The unpacked message: header, fields, data and checksum.
    private static func body(flashType: UInt8, address: UInt32, length: Int, data: [UInt8]) -> [UInt8] {
        var body = FM1Message.header(
            command: FM1Message.readCommand,
            bodyLength: data.count + FM1Message.fixedFieldsLength
        )
        body.append(flashType)
        body += FM1Message.littleEndian(address, byteCount: 4)
        body += FM1Message.littleEndian(UInt32(length), byteCount: 3)
        body += data
        body.append(FM1Message.checksum(body[FM1Message.Offset.flashType...]))
        return body
    }
}
