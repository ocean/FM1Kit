// Sample projects for tests, here and in apps that use SimulatedFM1. Their contents are a
// pattern, so they must never be written to a real FM-1.

@_spi(Testing)
extension OpenFirmwareProject {
    /// A version 4 project filled with a pattern, for ``SimulatedFM1``.
    ///
    /// - Parameter seed: Varies the pattern, so projects with different seeds differ.
    /// - Returns: A 4064-byte project.
    public static func sample(seed: Int) -> Self {
        var bytes = (0..<lengths[1]).map { UInt8(truncatingIfNeeded: $0 &* (seed | 1) &+ seed) }
        bytes[versionOffset] = 4
        guard let project = Self(bytes: bytes) else { preconditionFailure("A sample project is valid.") }
        return project
    }
}

extension OpenFirmwareProject {
    /// The workspace a simulated open firmware starts with.
    static let sampleWorkspace = sample(seed: 1)
}
