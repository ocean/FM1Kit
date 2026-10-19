/// M-VAVE's open firmware's project library protocol, which reads and writes projects, track
/// voices and the sample bank while the firmware runs.
///
/// A request is `F0 7D 46 4D 02`, the command, a 14-bit token (low 7 bits first), the payload
/// packed as in ``SevenBit``, and a checksum that makes the sum of everything between `F0` and
/// `F7` a multiple of 128. The reply repeats the token, sets bit 6 of the command and starts its
/// payload with a status: 0 for success, 1 for an empty slot, and 64 minus a negative error code
/// otherwise (71 for an invalid request, 72 for not enough memory). The firmware answers one
/// request at a time and answers an exact repeat with its cached reply. The layout follows
/// M-VAVE's open-source firmware (<https://github.com/m-vave/fm1_open>).
enum ProjectLibraryMessage {
    /// What every request and reply starts with after `F0`.
    static let prefix: [UInt8] = [0x7D, 0x46, 0x4D, 0x02]
    /// The bit a reply sets in the command.
    static let replyBit: UInt8 = 0x40
    /// The largest token.
    static let tokenMask = 0x3FFF
    /// The most bytes one read request asks for.
    static let maximumReadLength = 64

    /// The protocol's commands.
    enum Command: UInt8 {
        /// The library's layout: version, slot count, current slot, project length, clock mode
        /// and each track's sound source.
        case info = 0
        /// Captures something to read: kind (``Kind``) and target, answered with its LE16 length.
        case openRead = 1
        /// Reads part of what ``openRead`` captured: LE16 offset and a length up to 64.
        case read = 2
        /// Starts a write: kind, target and LE16 length.
        case openWrite = 3
        /// Writes part of it: LE16 offset, then up to 64 bytes.
        case write = 4
        /// Finishes a write with the data's CRC-32 (LE32), which applies it.
        case finishWrite = 5
        /// Abandons a read or write.
        case closeTransfer = 6
        /// Loads a project slot into the workspace, replacing it.
        case loadSlot = 8
        /// A slot's 12-character name, with status 1 when it's empty.
        case slotName = 9
        /// The sample bank's state (``SampleState``) and LE32 length.
        case sampleInfo = 11
        /// Reads part of the sample bank: LE32 offset and a length up to 64.
        case readSamples = 15
    }

    /// What ``Command/openRead`` and ``Command/openWrite`` transfer.
    enum Kind: UInt8 {
        /// The workspace: the project being edited.
        case project = 0
    }

    /// The sample bank states ``Command/sampleInfo`` reports.
    enum SampleState: UInt8 {
        case empty = 0
        case validating = 1
        case ready = 2
        case receiving = 3
        case error = 4
    }

    /// The status of a successful reply.
    static let success: UInt8 = 0
    /// The status of a reply about an empty slot.
    static let empty: UInt8 = 1

    /// Frames a request.
    ///
    /// - Parameters:
    ///   - command: The command.
    ///   - token: Tells this request's reply from others; 0 to ``tokenMask``.
    ///   - payload: The unpacked payload.
    /// - Returns: A complete `F0 … F7` message.
    static func request(_ command: Command, token: Int, payload: [UInt8] = []) -> [UInt8] {
        frame(command.rawValue, token: token, payload: payload)
    }

    /// Frames a message with a raw command, as requests and replies are.
    static func frame(_ command: UInt8, token: Int, payload: [UInt8]) -> [UInt8] {
        var body = prefix + [command, UInt8(token & 0x7F), UInt8((token >> 7) & 0x7F)] + SevenBit.pack(payload)
        let sum = body.reduce(0) { $0 + Int($1) }
        body.append(UInt8((128 - sum % 128) % 128))
        return [0xF0] + body + [0xF7]
    }

    /// A parsed request or reply.
    struct Parsed {
        /// The command, with bit 6 set in a reply.
        var command: UInt8
        /// The token that pairs a reply with its request.
        var token: Int
        /// The unpacked payload; a reply's starts with its status.
        var payload: [UInt8]
    }

    /// Parses a message: a reply, or a request for a simulated device.
    ///
    /// Fails for any other message, a checksum that doesn't match, or packing with stray bits.
    ///
    /// - Parameter sysex: A complete `F0 … F7` message.
    /// - Returns: The command (with any reply bit), token and unpacked payload.
    static func parse(_ sysex: [UInt8]) -> Parsed? {
        guard
            sysex.count >= 10, sysex.first == 0xF0, sysex.last == 0xF7,
            sysex[1...].starts(with: prefix)
        else {
            return nil
        }
        let body = sysex[1..<(sysex.count - 1)]
        guard body.allSatisfy({ $0 < 0x80 }), body.reduce(0, { $0 + Int($1) }).isMultiple(of: 128) else { return nil }
        let packed = sysex[8..<(sysex.count - 2)]
        let payload = SevenBit.unpack(packed)
        // Packing pads the last data byte's top bits with fewer than 7 zero bits, as the firmware checks.
        let paddingBits = packed.count * 7 - payload.count * 8
        guard paddingBits < 7, Int(packed.last ?? 0) >> (7 - paddingBits) == 0 else { return nil }
        return Parsed(command: sysex[5], token: Int(sysex[6]) | Int(sysex[7]) << 7, payload: payload)
    }
}
