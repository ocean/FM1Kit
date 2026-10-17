/// V15's factory voices, as M-VAVE's updater restores them after installing V15.
///
/// They're the first 16 KB of the official V15 package's enciphered `USR` part: four 4 KB banks
/// of 32 voices. Each 32-byte block of the part is deciphered with a key made from its offset in
/// the logical image.
extension FwscPackage {
    /// The length of the factory voices: four banks of 4 KB.
    static let factoryVoicesLength = 16_384
    /// The length of one voice bank.
    static let voiceBankLength = 4096
    /// SHA-256 of the factory voices, as M-VAVE's updater pins them.
    static let factoryVoicesSHA256 = "ecad0b8620f9d784d46c8da1e3c5de02c40214649ed8dec218026431046aad25"
    /// The block size the `USR` part is enciphered in.
    static let userDataBlockLength = 32
    /// The key seed for the `USR` part's blocks.
    static let userDataKeySeed: UInt16 = 0x980F

    /// True when this package carries V15's factory voices, so it can restore them with
    /// ``FM1Updater/restoreFactoryVoices(from:progress:)``: it's M-VAVE's official V15.
    public var hasFactoryVoices: Bool {
        factoryVoices() != nil
    }

    /// The factory voices, or `nil` unless this is the official V15 package and they match
    /// M-VAVE's checksum.
    func factoryVoices() -> [UInt8]? {
        guard OfficialFirmware.matching(self) == .v15 else { return nil }
        return voices(matching: Self.factoryVoicesSHA256)
    }

    /// The first 16 KB of the `USR` part, or `nil` unless it deciphers to its checksum and the
    /// voices have this SHA-256.
    func voices(matching sha256: String) -> [UInt8]? {
        guard
            let part = container.userData,
            part.isEnciphered,
            part.size >= Self.factoryVoicesLength,
            part.offset + part.storedSize <= logicalImage.count
        else {
            return nil
        }
        let plain = Self.decipherUserData(logicalImage, range: part.offset..<(part.offset + part.storedSize))
        guard FirmwareContainer.crc16(plain.prefix(part.size)) == part.checksum else { return nil }
        let voices = Array(plain.prefix(Self.factoryVoicesLength))
        return Self.sha256Hex(voices) == sha256 ? voices : nil
    }

    /// Deciphers (or enciphers) part of the logical image the way the `USR` part is stored: in
    /// 32-byte blocks, each keyed by its offset.
    static func decipherUserData(_ image: [UInt8], range: Range<Int>) -> [UInt8] {
        var plain: [UInt8] = []
        plain.reserveCapacity(range.count)
        for start in stride(from: range.lowerBound, to: range.upperBound, by: userDataBlockLength) {
            let end = min(start + userDataBlockLength, range.upperBound)
            let key = userDataKeySeed ^ UInt16(truncatingIfNeeded: start >> 2)
            plain += FirmwareContainer.decipher(image[start..<end], key: key)
        }
        return plain
    }
}
