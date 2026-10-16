import FM1Kit
import Foundation
import os

/// Prints an install's progress with timestamps, then the figures hardware stage D asks for: how
/// long each step took, how many requests staging and writing needed, and the longest silence.
final class InstallReport: Sendable {
    /// The step an install is on.
    enum Step: String {
        case starting = "Starting"
        case staging = "Staging"
        case waitingForLoader = "Waiting for the loader"
        case writing = "Writing"
        case checking = "Checking"
        case rebooting = "Restarting"
        case finished = "Finished"
    }

    /// Everything that changes as events arrive, guarded by one lock.
    struct State {
        var step = Step.starting
        var stepStart = ContinuousClock.now
        /// When the latest request arrived in this step, if any has.
        var lastProgress: ContinuousClock.Instant?
        var longestGap = Duration.zero
        var requests = 0
        var lastPrintedTenth = -1
        var summary: [String] = []
    }

    /// How often staging progress is printed, in requests.
    static let stagingPrintInterval = 25

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The step the install had reached.
    var step: Step {
        state.withLock { $0.step }
    }

    /// Records one update event, printing what changed.
    func record(_ event: UpdateEvent) {
        let lines: [String] = state.withLock { state in
            switch event {
            case .connected(let identity):
                return Self.begin(.staging, in: &state, note: "Connected to \(identity.text); staging")
            case .staging(let requests):
                Self.noteProgress(requests: requests, in: &state)
                return requests.isMultiple(of: Self.stagingPrintInterval) ? ["staging: \(requests) requests"] : []
            case .waitingForLoader:
                return Self.begin(.waitingForLoader, in: &state, note: "Staging accepted; waiting for the loader")
            case .loaderFound(let identity):
                return Self.begin(.writing, in: &state, note: "Loader answered as \(identity.text); writing")
            case .writing(let fraction, let requests):
                let restart = state.step == .checking ? Self.begin(.writing, in: &state, note: "Writing again") : []
                return restart + Self.noteFraction(fraction, requests: requests, in: &state)
            case .checking(let fraction, let requests):
                let start =
                    state.step == .checking
                    ? [] : Self.begin(.checking, in: &state, note: "The loader is reading the image again; checking")
                return start + Self.noteFraction(fraction, requests: requests, in: &state)
            case .rebooting:
                return Self.begin(.rebooting, in: &state, note: "Writing finished; restarting into the new firmware")
            case .finished(let identity):
                return Self.begin(.finished, in: &state, note: "The FM-1 reports \(identity.text)")
            }
        }
        for line in lines {
            print("\(timestamp())  \(line)")
        }
    }

    /// Prints how long each step took, including the one the install stopped in.
    func printSummary(total: Duration) {
        let summary = state.withLock { state in
            state.step == .finished ? state.summary : state.summary + [Self.describe(state, stoppedEarly: true)]
        }
        print("\nSummary:")
        for line in summary {
            print("  \(line)")
        }
        print("  Total: \(formatSeconds(total))")
    }

    /// Closes the current step and starts `next`, returning the lines to print.
    private static func begin(_ next: Step, in state: inout State, note: String) -> [String] {
        if state.step != .starting {
            state.summary.append(describe(state, stoppedEarly: false))
        }
        let now = ContinuousClock.now
        state.step = next
        state.stepStart = now
        state.lastProgress = nil
        state.longestGap = .zero
        state.requests = 0
        state.lastPrintedTenth = -1
        return [note]
    }

    /// Notes a progress event, tracking the longest silence between requests.
    private static func noteProgress(requests: Int, in state: inout State) {
        let now = ContinuousClock.now
        if let lastProgress = state.lastProgress {
            state.longestGap = max(state.longestGap, now - lastProgress)
        }
        state.lastProgress = now
        state.requests = requests
    }

    /// Notes a writing or checking event, returning a line each time another tenth is reached.
    private static func noteFraction(_ fraction: Double, requests: Int, in state: inout State) -> [String] {
        noteProgress(requests: requests, in: &state)
        let tenth = Int(fraction * 10)
        guard tenth > state.lastPrintedTenth else { return [] }
        state.lastPrintedTenth = tenth
        return ["\(state.step.rawValue.lowercased()): \(tenth * 10)%, \(requests) requests"]
    }

    /// One summary line for the current step.
    private static func describe(_ state: State, stoppedEarly: Bool) -> String {
        var line = "\(state.step.rawValue): \(formatSeconds(ContinuousClock.now - state.stepStart))"
        if [.staging, .writing, .checking].contains(state.step) {
            let longestGap = Int(milliseconds(state.longestGap).rounded())
            line += ", \(state.requests) requests, longest gap between requests \(longestGap) ms"
        }
        return stoppedEarly ? line + " (stopped here)" : line
    }
}

/// A duration as seconds with one decimal place, e.g. `12.3 s`.
func formatSeconds(_ duration: Duration) -> String {
    String(format: "%.1f s", milliseconds(duration) / 1000)
}
