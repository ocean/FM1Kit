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
    /// The loader is writing: it has read `fraction` (0 to 1) of the firmware's application
    /// area in `requests` reads.
    ///
    /// Every loader seen reads the whole area, but one that skipped part of it would stop short
    /// of 1.
    case writing(fraction: Double, requests: Int)
    /// The loader is reading the image again, probably checking what it wrote: it has re-read
    /// `fraction` (0 to 1) of what it wrote in `requests` reads. Not every loader does this.
    case checking(fraction: Double, requests: Int)
    /// Writing has finished and the device is restarting into its new firmware.
    case rebooting
    /// The device is running the new firmware and reports this identity.
    case finished(FM1Identity)
}
