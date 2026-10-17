/// What a device (or a `.fwsc` package) says it is, e.g. `FM-1_916` or `ota-FM-1_009`.
///
/// After M-VAVE's open firmware is armed, its update loader reports `ota-FM1C_` and the first 16
/// hex digits of the build it was armed with, e.g. `ota-FM1C_db1642b2b6fa5c2c`: see
/// ``armedBuildPrefix``. Its ``version`` is 0.
///
/// The number after the underscore is set by whoever built the firmware. Many custom firmwares
/// share a number (lots report `FM-1_900`), so an identity narrows down what is installed but
/// cannot always name it.
public struct FM1Identity: Hashable, Sendable, CustomStringConvertible, Codable {
    /// What the update loader puts before the model, as in `ota-FM-1_009`.
    public static let loaderPrefix = "ota-"

    /// The full text, e.g. `FM-1_916`.
    public let text: String

    /// The part before the underscore, e.g. `FM-1` or `ota-FM-1`.
    public let model: String

    /// The number after the underscore; 0 for an armed open firmware loader.
    public let version: Int

    /// For the loader of an armed open firmware, the first 16 hex digits of the build it was
    /// armed with; `nil` for every other identity.
    public let armedBuildPrefix: String?

    /// The model an armed open firmware's loader reports.
    static let armedLoaderModel = "ota-FM1C"
    /// How many hex digits of the build an armed open firmware's loader reports.
    static let armedBuildPrefixLength = 16

    /// Parses an identity.
    ///
    /// Fails when the text isn't printable ASCII ending in an underscore and digits.
    ///
    /// - Parameter text: Text such as `FM-1_916`.
    public init?(text: String) {
        guard
            let separator = text.lastIndex(of: "_"),
            separator != text.startIndex
        else {
            return nil
        }
        let model = String(text[..<separator])
        let digits = text[text.index(after: separator)...]
        if model.lowercased() == Self.armedLoaderModel.lowercased() {
            guard
                digits.count == Self.armedBuildPrefixLength,
                digits.allSatisfy({ $0.isASCII && $0.isHexDigit })
            else {
                return nil
            }
            self.text = text
            self.model = model
            self.version = 0
            self.armedBuildPrefix = digits.lowercased()
            return
        }
        guard
            text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
            !digits.isEmpty,
            digits.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
            let version = Int(digits)
        else {
            return nil
        }
        self.text = text
        self.model = model
        self.version = version
        self.armedBuildPrefix = nil
    }

    /// Makes an identity from its parts.
    ///
    /// - Parameters:
    ///   - model: The model, e.g. `FM-1` or `ota-FM-1`: printable ASCII without spaces.
    ///   - version: The number after the underscore; not negative.
    public init(model: String, version: Int) {
        precondition(
            !model.isEmpty && model.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) },
            "An identity's model is printable ASCII without spaces."
        )
        precondition(version >= 0, "An identity's version isn't negative.")
        self.text = "\(model)_\(version)"
        self.model = model
        self.version = version
        self.armedBuildPrefix = nil
    }

    /// True when the update loader is running rather than a firmware (mid-update, or USB recovery mode).
    public var isLoader: Bool {
        model.lowercased().hasPrefix(Self.loaderPrefix)
    }

    /// True for M-VAVE's open firmware and builds of it: `FM-1_8` and six digits (`FM-1_8000012`
    /// for V12), or `FM1_COMMUNITY_` and a number.
    ///
    /// Open firmware has to be armed before an update; see ``FM1Capability``.
    public var isOpenFirmware: Bool {
        (model == "FM-1" && Self.openVersions.contains(version)) || model == "FM1_COMMUNITY"
    }

    /// The versions M-VAVE's open firmware reports.
    static let openVersions = 8_000_000...8_999_999

    /// The hardware model with any loader prefix removed, e.g. `FM-1`; an armed open firmware's
    /// loader runs on an FM-1.
    public var hardwareModel: String {
        if armedBuildPrefix != nil { return FwscPackage.expectedModel }
        return isLoader ? String(model.dropFirst(Self.loaderPrefix.count)) : model
    }

    /// True when this is an update loader for `model`, such as `FM-1`.
    func isLoader(for model: String) -> Bool {
        isLoader && hardwareModel == model
    }

    /// The identity as the device reports it, e.g. `FM-1_916`.
    public var description: String { text }

    /// Parses the device's reply to ``FM1Message/handshakeQuery``.
    ///
    /// Fails for any other message, or a reply whose checksum doesn't match.
    ///
    /// - Parameter sysex: A complete `F0 … F7` message.
    public init?(handshakeReply sysex: [UInt8]) {
        guard
            let body = FM1Message.unframe(sysex),
            body.count == Self.replyLength,
            body.starts(with: FM1Message.prefix),
            body[FM1Message.Offset.command] == FM1Message.identityCommand,
            FM1Message.checksum(body[FM1Message.headerLength..<(Self.replyLength - 1)]) == body[Self.replyLength - 1]
        else {
            return nil
        }
        let textBytes = body[FM1Message.headerLength..<(Self.replyLength - 1)].prefix { $0 != 0 }
        guard textBytes.allSatisfy({ $0 < 0x80 }) else { return nil }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: textBytes.map(Unicode.Scalar.init))
        self.init(text: String(text))
    }

    /// Encodes the handshake reply as the device sends it, for simulated devices and tests.
    ///
    /// - Returns: A complete `F0 … F7` message carrying this identity.
    public func handshakeReply() -> [UInt8] {
        let textLength = Self.replyLength - FM1Message.headerLength - 1
        var body = FM1Message.header(command: FM1Message.identityCommand, bodyLength: textLength)
        body += Array(text.utf8.prefix(textLength))
        body += Array(repeating: 0, count: Self.replyLength - 1 - body.count)
        body.append(FM1Message.checksum(body[FM1Message.headerLength...]))
        return FM1Message.frame(body)
    }

    /// The handshake reply's length once unpacked.
    static let replyLength = 34

    /// Decodes an identity stored as its text, e.g. `"FM-1_916"`.
    ///
    /// - Parameter decoder: The decoder to read from.
    /// - Throws: `DecodingError.dataCorrupted` when the text isn't an identity.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let identity = Self(text: text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(text)\" isn't an FM-1 identity.")
        }
        self = identity
    }

    /// Encodes the identity as its text, e.g. `"FM-1_916"`.
    ///
    /// - Parameter encoder: The encoder to write to.
    /// - Throws: Any error the encoder throws.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}
