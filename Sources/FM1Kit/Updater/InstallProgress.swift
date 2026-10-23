/// An install's progress as one bar: a fraction from 0 to 1 that never goes backwards, and a
/// friendly stage.
///
/// ``UpdateEvent``s follow the protocol closely: staging has no known length, the loader's
/// checking pass happens only with some firmwares, and restarts take a while with nothing to
/// report. This folds them into a single bar that's simple to show. Feed it every event:
///
/// ```swift
/// var progress = InstallProgress()
/// try await updater.install(package, options: options) { event in
///     Task { @MainActor in
///         progress.record(event)
///         bar.value = progress.fraction
///         label.text = progress.stage.title
///     }
/// }
/// ```
///
/// The bar's shares are rough guides from installs on real FM-1s, not timings.
public struct InstallProgress: Sendable, Hashable {
    /// The part of the install that's happening, as a person would describe it.
    public enum Stage: Sendable, Hashable, CaseIterable {
        /// The FM-1 is checking the firmware before it restarts.
        case gettingReady
        /// The FM-1 is writing the new firmware.
        case installing
        /// The FM-1 is reading back what it wrote, which only some firmwares do.
        case checking
        /// The FM-1 is restarting, and FM1Kit is waiting for it to come back.
        case restarting

        /// A short title for the stage, such as "Getting ready".
        public var title: String {
            switch self {
            case .gettingReady: "Getting ready"
            case .installing: "Installing"
            case .checking: "Checking"
            case .restarting: "Restarting"
            }
        }
    }

    /// The stage now.
    public private(set) var stage = Stage.gettingReady
    /// How far the whole install has got, from 0 to 1; it never goes down.
    public private(set) var fraction = 0.0
    /// True once the FM-1 is running the new firmware.
    public private(set) var isFinished = false

    // Where each step starts on the bar.
    static let stagingShare = 0.15
    static let loaderFoundAt = 0.22
    static let writingEndsAt = 0.8
    static let checkingEndsAt = 0.92
    /// Staging reads after which the staging share is about two-thirds full; V15 stages in
    /// about 50, Felucca in about 100.
    static let stagingScale = 50.0

    /// Starts at zero, getting ready.
    public init() {}

    /// Moves the bar on for an event from ``FM1Updater/install(_:options:events:)``,
    /// ``FM1Updater/resume(_:events:)`` or ``FM1Updater/installBootloader(_:events:)``.
    ///
    /// - Parameter event: The event just reported.
    public mutating func record(_ event: UpdateEvent) {
        switch event {
        case .connected:
            advance(to: .gettingReady, 0)
        case .staging(let requests):
            // Staging's length isn't known in advance, so approach the end of its share.
            let share = 1 - 1 / (1 + Double(requests) / Self.stagingScale)
            advance(to: .gettingReady, Self.stagingShare * share)
        case .waitingForLoader:
            advance(to: .restarting, Self.stagingShare)
        case .loaderFound:
            advance(to: .installing, Self.loaderFoundAt)
        case .writing(let written, _):
            advance(to: .installing, Self.loaderFoundAt + (Self.writingEndsAt - Self.loaderFoundAt) * written)
        case .checking(let checked, _):
            advance(to: .checking, Self.writingEndsAt + (Self.checkingEndsAt - Self.writingEndsAt) * checked)
        case .rebooting:
            advance(to: .restarting, Self.checkingEndsAt)
        case .finished:
            advance(to: .restarting, 1)
            isFinished = true
        }
    }

    /// Moves to `stage`, and to `value` unless the bar is already past it.
    private mutating func advance(to stage: Stage, _ value: Double) {
        self.stage = stage
        fraction = max(fraction, min(value, 1))
    }
}
