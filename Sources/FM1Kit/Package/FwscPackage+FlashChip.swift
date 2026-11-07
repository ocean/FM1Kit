/// Which of the FM-1's flash chips a firmware's code checks for, read from the package.
///
/// Firmwares that write the flash themselves read its JEDEC ID first, and those built on
/// Felucca's code keep saves in RAM when it isn't one they know. Their code holds each ID they
/// accept as a 32-bit constant, so a firmware that knows the newer chip holds both.
public enum FlashChipSupport: Sendable, Hashable {
    /// Its code names the newer chip, as well as the first in every firmware seen, so it saves
    /// on either.
    case bothChips
    /// Its code names the first FM-1s' chip alone. On FM-1s sold since autumn 2026 such a
    /// firmware usually keeps saves only until switched off, and often can't install another
    /// firmware afterwards.
    case firstChipOnly
    /// Its code names neither chip: it doesn't check, and should save on both. V15 is one.
    case noCheck
}

extension FwscPackage {
    /// Which flash chips the firmware's code checks for, or `nil` for a package that isn't a
    /// firmware or whose code can't be read.
    ///
    /// The constants show which chips the code compares against, not what it does with them. M-VAVE's
    /// V16 names the first chip and another, but not the newer one, and whether it saves on the
    /// newer chip isn't known.
    public var flashChipSupport: FlashChipSupport? {
        guard isFirmware, let code = firmwareCode else { return nil }
        let first = code.contains(Self.constant(FM1FlashChip.p25q80))
        let newer = code.contains(Self.constant(FM1FlashChip.uc25hq80))
        switch (first, newer) {
        case (true, true), (false, true): return .bothChips
        case (true, false): return .firstChipOnly
        case (false, false): return .noCheck
        }
    }

    /// A 32-bit constant as code stores it, least significant byte first.
    static func constant(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
