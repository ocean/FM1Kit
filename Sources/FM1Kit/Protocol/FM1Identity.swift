import Foundation

/// What a device (or a `.fwsc` package) says it is, e.g. `FM-1_916` or `ota-FM-1_009`.
///
/// The number after the underscore is set by whoever built the firmware. Many custom firmwares
/// share a number (lots report `FM-1_900`), so an identity narrows down what is installed but
/// cannot always name it.
public struct FM1Identity: Hashable, Sendable, CustomStringConvertible {
    /// What the update loader puts before the model, as in `ota-FM-1_009`.
    public static let loaderPrefix = "ota-"

    /// The full text, e.g. `FM-1_916`.
    public let text: String

    /// The part before the underscore, e.g. `FM-1` or `ota-FM-1`.
    public let model: String

    /// The number after the underscore.
    public let version: Int

    /// Parses text such as `FM-1_916`; `nil` unless it ends in an underscore and a number.
    public init?(text: String) {
        guard
            let separator = text.lastIndex(of: "_"),
            separator != text.startIndex
        else {
            return nil
        }
        let model = String(text[..<separator])
        let digits = text[text.index(after: separator)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let version = Int(digits) else {
            return nil
        }
        self.text = text
        self.model = model
        self.version = version
    }

    /// True when the update loader is running rather than a firmware (mid-update, or USB rescue).
    public var isLoader: Bool {
        model.lowercased().hasPrefix(Self.loaderPrefix)
    }

    /// The hardware model with any loader prefix removed, e.g. `FM-1`.
    public var hardwareModel: String {
        isLoader ? String(model.dropFirst(Self.loaderPrefix.count)) : model
    }

    public var description: String { text }

    /// Parses the device's reply to `FM1Message.handshakeQuery`.
    public init?(handshakeReply sysex: [UInt8]) {
        guard
            let body = FM1Message.unframe(sysex),
            body.count == Self.replyLength,
            Array(body[0..<2]) == FM1Message.prefix,
            body[2] == FM1Message.identityCommand
        else {
            return nil
        }
        let textBytes = body[6..<(Self.replyLength - 1)].prefix { $0 != 0 }
        guard let text = String(bytes: textBytes, encoding: .ascii) else {
            return nil
        }
        self.init(text: text)
    }

    /// Encodes the handshake reply the way the device does (used by the simulated device and the tests).
    public func handshakeReply() -> [UInt8] {
        let textLength = Self.replyLength - FM1Message.headerLength - 1
        var body = FM1Message.header(command: FM1Message.identityCommand, bodyLength: textLength)
        body += Array(text.utf8.prefix(textLength))
        body += Array(repeating: 0, count: Self.replyLength - 1 - body.count)
        body.append(FM1Message.checksum(body[6...]))
        return FM1Message.frame(body)
    }

    static let replyLength = 34
}
