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
        case checking = "Second pass"
        case writingResources = "Writing resources"
        case firmwareResources = "Firmware writing resources"
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
        var resourcesProblem: FM1UpdateError?
    }

    /// What's printed when the loader starts a second pass.
    static let secondPassNote = "The loader is reading the image again; Felucca's loader writes in this pass"

    /// What's printed when the loader starts writing the firmware's resources.
    static let resourcesNote = "The loader is writing the firmware's resources (its samples); keep the FM-1 on"

    /// What's printed when the new firmware starts writing the resources its loader left out.
    static let firmwareResourcesNote = "The firmware is writing its resources (its samples); keep the FM-1 on"

    /// How often staging progress is printed, in requests.
    static let stagingPrintInterval = 25

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The step the install had reached.
    var step: Step {
        state.withLock { $0.step }
    }

    /// Why the new firmware didn't write its resources, if it didn't.
    var resourcesProblem: FM1UpdateError? {
        state.withLock { $0.resourcesProblem }
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
                    ? []
                    : Self.begin(.checking, in: &state, note: Self.secondPassNote)
                return start + Self.noteFraction(fraction, requests: requests, in: &state)
            case .writingResources(let fraction, let requests):
                return Self.noteResources(fraction, requests: requests, in: &state)
            case .resourcesNotWritten(let error):
                // Said after the FM-1 reports, as the firmware is answering by then.
                state.resourcesProblem = error
                return []
            case .rebooting:
                return Self.begin(.rebooting, in: &state, note: "Writing finished; restarting into the new firmware")
            case .finished(let identity):
                let reports = Self.begin(.finished, in: &state, note: "The FM-1 reports \(identity.text)")
                return reports + (state.resourcesProblem == nil ? [] : ["The firmware didn't write its resources"])
            }
        }
        for line in lines {
            print(Style.progress(line))
        }
    }

    /// Prints how long each step took, including the one the install stopped in.
    func printSummary(total: Duration) {
        let summary = state.withLock { state in
            state.step == .finished ? state.summary : state.summary + [Self.describe(state, stoppedEarly: true)]
        }
        Style.heading("Summary")
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

    /// Notes the resources being written: by the loader, or by the new firmware once it's back.
    private static func noteResources(_ fraction: Double, requests: Int, in state: inout State) -> [String] {
        let start: [String] =
            switch state.step {
            case .writingResources, .firmwareResources: []
            case .rebooting: begin(.firmwareResources, in: &state, note: firmwareResourcesNote)
            default: begin(.writingResources, in: &state, note: resourcesNote)
            }
        return start + noteFraction(fraction, requests: requests, in: &state)
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
        if [.staging, .writing, .checking, .writingResources, .firmwareResources].contains(state.step) {
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
