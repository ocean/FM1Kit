/// The FM-1's flash chips, by JEDEC ID.
///
/// FM-1s sold since autumn 2026 have a UC25HQ80 instead of the first units' Puya P25Q80. Both are
/// 1 MB and take the same commands, but firmwares that check for the P25Q80 alone keep saves only
/// until the FM-1 is switched off, and often can't take an update. Firmwares built on felucca-bsp
/// since November 2026 report the chip in their handshake reply
/// (``FM1Identity/flashChipID(inHandshakeReply:)``); in download mode the flash loader reads it.
public enum FM1FlashChip {
    /// The Puya P25Q80 of the first FM-1s.
    public static let p25q80: UInt32 = 0x85_6014
    /// The UC25HQ80 of FM-1s sold since autumn 2026.
    public static let uc25hq80: UInt32 = 0xB3_6014

    /// The chip's name, such as "UC25HQ80", or `nil` for a chip FM-1s don't have.
    ///
    /// - Parameter id: A JEDEC ID.
    /// - Returns: The name.
    public static func name(_ id: UInt32) -> String? {
        switch id {
        case p25q80: "P25Q80"
        case uc25hq80: "UC25HQ80"
        default: nil
        }
    }
}
