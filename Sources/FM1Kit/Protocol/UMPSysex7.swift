/// Conversion between whole `F0 ... F7` SysEx messages and Universal MIDI Packet "Data 64"
/// (message type 3) packets, which is how CoreMIDI's event-list API carries 7-bit SysEx.
///
/// Each packet is two 32-bit words carrying up to six data bytes:
///
///     word 0: 0x3 | group | status | byte count | data 0 | data 1
///     word 1: data 2 | data 3 | data 4 | data 5
///
/// Status is 0 for a complete message, 1 for start, 2 for continue and 3 for end.
public enum UMPSysex7 {
    /// The UMP message type for 7-bit SysEx ("Data 64").
    public static let messageType: UInt32 = 0x3
    static let bytesPerPacket = 6

    enum Status: UInt32 {
        case complete = 0
        case start = 1
        case `continue` = 2
        case end = 3
    }

    /// Splits a SysEx message into UMP packets; leading `F0` and trailing `F7` are optional.
    public static func packets(for sysex: [UInt8], group: UInt8 = 0) -> [(UInt32, UInt32)] {
        var payload = ArraySlice(sysex)
        if payload.first == 0xF0 { payload = payload.dropFirst() }
        if payload.last == 0xF7 { payload = payload.dropLast() }

        guard payload.count > bytesPerPacket else {
            return [packet(status: .complete, group: group, bytes: payload)]
        }
        var packets: [(UInt32, UInt32)] = []
        var offset = payload.startIndex
        while offset < payload.endIndex {
            let end = min(offset + bytesPerPacket, payload.endIndex)
            let status: Status = offset == payload.startIndex ? .start : (end == payload.endIndex ? .end : .continue)
            packets.append(packet(status: status, group: group, bytes: payload[offset..<end]))
            offset = end
        }
        return packets
    }

    static func packet(status: Status, group: UInt8, bytes: ArraySlice<UInt8>) -> (UInt32, UInt32) {
        var data = [UInt8](repeating: 0, count: bytesPerPacket)
        for (index, byte) in bytes.enumerated() {
            data[index] = byte & 0x7F
        }
        let word0 =
            messageType << 28
            | UInt32(group & 0x0F) << 24
            | status.rawValue << 20
            | UInt32(bytes.count) << 16
            | UInt32(data[0]) << 8
            | UInt32(data[1])
        let word1 = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 | UInt32(data[4]) << 8 | UInt32(data[5])
        return (word0, word1)
    }

    /// The number of 32-bit words in a UMP, from its message type (the top four bits of word 0).
    public static func wordCount(forFirstWord word: UInt32) -> Int {
        switch word >> 28 {
        case 0x0, 0x1, 0x2, 0x6, 0x7:
            return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA:
            return 2
        case 0xB, 0xC:
            return 3
        default:
            return 4
        }
    }

    /// Reassembles SysEx messages from a stream of UMP words.
    ///
    /// It's a value type with no locking: feed it from one place, such as a port's receive callback.
    public struct Assembler: Sendable {
        /// Guards against a stream that starts but never ends.
        public static let maximumMessageLength = 64 * 1024

        private var buffer: [UInt8]?

        /// An assembler waiting for the start of a message.
        public init() {}

        /// Feeds the two words of a type 3 packet; returns a complete `F0 ... F7` message when one ends.
        public mutating func consume(_ word0: UInt32, _ word1: UInt32) -> [UInt8]? {
            guard word0 >> 28 == messageType, let status = Status(rawValue: (word0 >> 20) & 0x0F) else {
                return nil
            }
            let count = min(Int((word0 >> 16) & 0x0F), bytesPerPacket)
            let all: [UInt8] = [
                UInt8(truncatingIfNeeded: word0 >> 8), UInt8(truncatingIfNeeded: word0),
                UInt8(truncatingIfNeeded: word1 >> 24), UInt8(truncatingIfNeeded: word1 >> 16),
                UInt8(truncatingIfNeeded: word1 >> 8), UInt8(truncatingIfNeeded: word1),
            ]
            let bytes = all.prefix(count)

            switch status {
            case .complete:
                buffer = nil
                return [0xF0] + bytes + [0xF7]
            case .start:
                buffer = Array(bytes)
                return nil
            case .continue:
                buffer?.append(contentsOf: bytes)
                if (buffer?.count ?? 0) > Self.maximumMessageLength { buffer = nil }
                return nil
            case .end:
                guard let started = buffer else { return nil }
                buffer = nil
                return [0xF0] + started + bytes + [0xF7]
            }
        }
    }
}
