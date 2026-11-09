/// What a SysEx message to or from an FM-1 is, in words: for monitors, logs and replays.
///
/// It names the update protocol's messages (``FM1Message``), V15's voice bank messages, M-VAVE's
/// open firmware's capability, arming and project library messages, and MIDI's device inquiry.
/// Anything else is `other`.
public struct FM1MessageDescription: Equatable, Sendable {
    /// Which way a message went.
    public enum Direction: Sendable {
        case toDevice
        case fromDevice
    }

    /// A short name for the message, such as `read`, `handshake` or `identity FM-1_015`.
    ///
    /// `install --log` writes it as the log's `kind`, so it stays the same from release to release.
    public let kind: String

    /// What the message carries, such as `0x00004000, 512 bytes`; empty when there's nothing more to say.
    public let detail: String

    /// Describes a message.
    ///
    /// - Parameters:
    ///   - sysex: A complete `F0 … F7` message.
    ///   - direction: Which way it went: some messages mean different things each way.
    public init(_ sysex: [UInt8], direction: Direction) {
        (kind, detail) = Self.describe(sysex, direction)
    }

    /// The kind and detail, joined for printing.
    public var text: String {
        detail.isEmpty ? kind : "\(kind): \(detail)"
    }

    private static func describe(_ sysex: [UInt8], _ direction: Direction) -> (String, String) {
        guard sysex.count >= 2, sysex.first == 0xF0, sysex.last == 0xF7 else {
            return ("incomplete", "\(sysex.count) bytes without F0 … F7")
        }
        if sysex == FM1Message.handshakeQuery {
            return ("handshake", "asks who the device is")
        }
        if sysex == FM1Message.fullIdentityQuery {
            return ("full identity query", "asks for the whole identity")
        }
        if sysex == FM1Message.upgradeCommand {
            return ("upgrade", "starts an update session")
        }
        if direction == .fromDevice, let identity = FM1Identity(handshakeReply: sysex) {
            return ("identity \(identity.text)", identityDetail(identity, sysex))
        }
        if direction == .fromDevice, let read = FM1ReadRequest(sysex: sysex) {
            return readDescription(read)
        }
        if direction == .toDevice, let (request, data) = FM1ReadRequest.parseResponse(sysex) {
            return ("response", request.isFinish ? "success" : range(request, length: data.count))
        }
        if let library = ProjectLibraryMessage.parse(sysex) {
            return libraryDescription(library)
        }
        if let description = updateCommandDescription(sysex, direction) {
            return description
        }
        if let description = deviceInquiryDescription(sysex) {
            return description
        }
        return (direction == .toDevice ? "response" : "other", "\(sysex.count) bytes")
    }

    /// The loader or firmware, and the flash chip when the reply carries one.
    private static func identityDetail(_ identity: FM1Identity, _ sysex: [UInt8]) -> String {
        var parts = [identity.isLoader ? "update loader" : "firmware"]
        if let chip = FM1Identity.flashChipID(inHandshakeReply: sysex) {
            parts.append("flash chip " + (FM1FlashChip.name(chip) ?? hex(chip, digits: 6)))
        }
        return parts.joined(separator: ", ")
    }

    private static func readDescription(_ read: FM1ReadRequest) -> (String, String) {
        switch read.address {
        case FM1Message.stageFinishAddress:
            ("finish", "staging done; restarting into the update loader")
        case FM1Message.writeFinishAddress:
            ("finish", "writing done; restarting")
        default:
            ("read", range(read, length: read.length))
        }
    }

    /// The address and length, and the flash type when it isn't the firmware image's.
    private static func range(_ request: FM1ReadRequest, length: Int) -> String {
        let flashType = request.flashType == 0 ? "" : ", flash type \(request.flashType)"
        return hex(request.address, digits: 8) + ", \(length) bytes" + flashType
    }

    /// Open firmware's capability and arming messages, and V15's voice bank messages, either way.
    private static func updateCommandDescription(_ sysex: [UInt8], _ direction: Direction) -> (String, String)? {
        let body = SevenBit.unpack(sysex.dropFirst().dropLast())
        guard body.count > FM1Message.Offset.command, body.starts(with: FM1Message.prefix) else { return nil }
        let command = body[FM1Message.Offset.command]
        let name: String
        switch command {
        case FM1Message.acknowledgementCommand: name = "acknowledgement"
        case FM1Message.voiceEraseCommand: name = "voice erase"
        case FM1Message.voiceWriteCommand: name = "voice write"
        case FM1Message.capabilityCommand: name = "capability"
        case FM1Message.armCommand: name = "arm"
        default: return ("update command 0x\(hex(command))", "not one FM1Kit knows")
        }
        guard let (_, payload) = FM1Message.parseCommand(sysex) else {
            return (name, "checksum or length doesn't match")
        }
        return (name, updateCommandDetail(command, payload, direction))
    }

    private static func updateCommandDetail(_ command: UInt8, _ payload: [UInt8], _ direction: Direction) -> String {
        switch command {
        case FM1Message.acknowledgementCommand:
            return payload == [0] ? "done" : "status \(payload.map { String($0) }.joined(separator: " "))"
        case FM1Message.voiceEraseCommand where payload.count >= 5:
            return "bank at " + hex(FM1Message.readLittleEndian(payload, at: 1, byteCount: 4), digits: 8)
        case FM1Message.voiceWriteCommand where payload.count >= 8:
            let address = FM1Message.readLittleEndian(payload, at: 1, byteCount: 4)
            let length = FM1Message.readLittleEndian(payload, at: 5, byteCount: 3)
            return hex(address, digits: 8) + ", \(length) bytes"
        case FM1Message.capabilityCommand where direction == .fromDevice:
            guard let capability = FM1Capability(payload: payload) else {
                return "\(payload.count) bytes, not understood"
            }
            let state = capability.isReady ? "ready" : "state \(capability.state)"
            let error = capability.errorCode == 0 ? "" : ", error \(capability.errorCode)"
            return "family \(capability.family), \(state), build \(capability.buildID.hex.prefix(16))…" + error
        case FM1Message.capabilityCommand:
            return "asks about update support"
        case FM1Message.armCommand where direction == .toDevice:
            return "arms the update, \(payload.count) bytes"
        default:
            return payload.count == 1 ? "status \(payload[0])" : "\(payload.count) bytes"
        }
    }

    private static func libraryDescription(_ message: ProjectLibraryMessage.Parsed) -> (String, String) {
        let isReply = message.command & ProjectLibraryMessage.replyBit != 0
        let command = message.command & 0x3F
        let names: [UInt8: String] = [
            0: "info", 1: "open read", 2: "read", 3: "open write", 4: "write", 5: "finish write",
            6: "close", 8: "load slot", 9: "slot name", 11: "sample info", 15: "read samples",
        ]
        let kind = "library " + (names[command] ?? "command \(command)") + (isReply ? " reply" : "")
        var parts = ["token \(message.token)"]
        if isReply, let status = message.payload.first {
            parts.append(libraryStatus(status))
            parts.append("\(message.payload.count - 1) bytes")
        } else if let range = libraryRange(command, message.payload) {
            parts.append(range)
        } else if !message.payload.isEmpty {
            parts.append("\(message.payload.count) bytes")
        }
        return (kind, parts.joined(separator: ", "))
    }

    /// Where a library read or write is: a 16-bit offset for projects, 32-bit for the sample bank.
    private static func libraryRange(_ command: UInt8, _ payload: [UInt8]) -> String? {
        let read = ProjectLibraryMessage.Command.read.rawValue
        let write = ProjectLibraryMessage.Command.write.rawValue
        let readSamples = ProjectLibraryMessage.Command.readSamples.rawValue
        switch command {
        case read where payload.count == 3:
            return "offset \(FM1Message.readLittleEndian(payload, at: 0, byteCount: 2)), \(payload[2]) bytes"
        case write where payload.count >= 2:
            return "offset \(FM1Message.readLittleEndian(payload, at: 0, byteCount: 2)), \(payload.count - 2) bytes"
        case readSamples where payload.count == 5:
            return "offset \(FM1Message.readLittleEndian(payload, at: 0, byteCount: 4)), \(payload[4]) bytes"
        default:
            return nil
        }
    }

    private static func libraryStatus(_ status: UInt8) -> String {
        switch status {
        case ProjectLibraryMessage.success: "ok"
        case ProjectLibraryMessage.empty: "empty"
        case 71: "invalid request"
        case 72: "not enough memory"
        default: "error \(Int(status) - 64)"
        }
    }

    /// MIDI's universal device inquiry, `F0 7E <device> 06 01 F7`, and its reply.
    private static func deviceInquiryDescription(_ sysex: [UInt8]) -> (String, String)? {
        guard sysex.count >= 6, sysex[1] == 0x7E, sysex[3] == 0x06 else { return nil }
        switch sysex[4] {
        case 0x01:
            return ("device inquiry", "device \(sysex[2])")
        case 0x02 where sysex.count >= 15:
            let manufacturer = sysex[5] == 0 ? Array(sysex[5...7]) : [sysex[5]]
            let rest = sysex[(5 + manufacturer.count)..<(sysex.count - 1)]
            return (
                "device inquiry reply",
                "manufacturer " + manufacturer.map { hex($0) }.joined(separator: " ")
                    + ", family, model and version " + rest.map { hex($0) }.joined(separator: " ")
            )
        default:
            return nil
        }
    }

    private static func hex(_ byte: UInt8) -> String {
        String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
    }

    private static func hex(_ value: UInt32, digits: Int) -> String {
        "0x" + String(value, radix: 16, uppercase: true).leftPadded(to: digits)
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
