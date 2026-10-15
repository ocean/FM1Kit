/// The FM-1 update protocol's 8-to-7-bit packing.
///
/// The whole unpacked message is treated as one continuous bit stream, least significant bit
/// first, and cut into 7-bit SysEx data bytes. This is not the common "MSB byte + 7 bytes"
/// scheme, so it must not be swapped for one.
public enum SevenBit {
    /// Packs 8-bit bytes into 7-bit SysEx data bytes.
    ///
    /// - Parameter bytes: The unpacked message.
    /// - Returns: Data bytes for between `F0` and `F7`, each below `0x80`; the last is padded with zero bits.
    public static func pack(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var packed: [UInt8] = []
        packed.reserveCapacity(bytes.underestimatedCount * 8 / 7 + 1)
        var accumulator: UInt32 = 0
        var bitCount = 0
        for byte in bytes {
            accumulator |= UInt32(byte) << bitCount
            bitCount += 8
            while bitCount >= 7 {
                packed.append(UInt8(accumulator & 0x7F))
                accumulator >>= 7
                bitCount -= 7
            }
        }
        if bitCount > 0 {
            packed.append(UInt8(accumulator & 0x7F))
        }
        return packed
    }

    /// Unpacks 7-bit SysEx data bytes into 8-bit bytes.
    ///
    /// - Parameter septets: Data bytes from between `F0` and `F7`; any top bit is ignored.
    /// - Returns: The unpacked message, without the padding bits that end the last data byte.
    public static func unpack(_ septets: some Sequence<UInt8>) -> [UInt8] {
        var unpacked: [UInt8] = []
        unpacked.reserveCapacity(septets.underestimatedCount * 7 / 8)
        var accumulator: UInt32 = 0
        var bitCount = 0
        for septet in septets {
            accumulator |= UInt32(septet & 0x7F) << bitCount
            bitCount += 7
            while bitCount >= 8 {
                unpacked.append(UInt8(accumulator & 0xFF))
                accumulator >>= 8
                bitCount -= 8
            }
        }
        return unpacked
    }
}
