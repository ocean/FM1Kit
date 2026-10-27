/// Telling a firmware's refusal of a package from a stalled install, by where staging stopped.
extension FM1Updater {
    /// True when staging stopped on a read of the package's boot area, as Felucca's platform does
    /// when the FM-1's bootloader isn't the one the package brings: it reads the boot area in
    /// order, comparing each block with the FM-1's, and gives up at the first difference.
    static func refusedBootloader(_ staging: ServeOutcome, of package: FwscPackage) -> Bool {
        guard let boot = package.bootAreaRange, let last = staging.lastRead else { return false }
        return boot.contains(last.lowerBound)
    }

    /// True when staging stopped, still connected, after reading only the package's header, as
    /// Felucca's platform does when it refuses a package before looking at its parts: every
    /// firmware that stages a package reads on into its parts.
    static func refusedPackage(_ staging: ServeOutcome, of package: FwscPackage) -> Bool {
        guard !staging.lost, let last = staging.lastRead else { return false }
        return package.headerRange.contains(last.lowerBound)
    }
}
