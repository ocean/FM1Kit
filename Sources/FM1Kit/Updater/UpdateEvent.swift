/// Progress reported during an update, in the order the steps happen.
public enum UpdateEvent: Sendable, Hashable {
    /// The device answered and the update has started.
    case connected(FM1Identity)
    /// The device is checking the package before restarting into its loader, and has made
    /// `requests` reads so far.
    case staging(requests: Int)
    /// The device accepted the package and is restarting into its update loader.
    case waitingForLoader
    /// The update loader answered, and writing is about to start.
    case loaderFound(FM1Identity)
    /// The loader is writing: it has read `fraction` (0 to 1) of the image in `requests` reads.
    case writing(fraction: Double, requests: Int)
    /// Writing has finished and the device is restarting into its new firmware.
    case rebooting
    /// The device is running the new firmware and reports this identity.
    case finished(FM1Identity)
}
