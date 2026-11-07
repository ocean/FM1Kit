extension FM1Updater {
    /// Answers the loader's reads until it asks to finish, the package's firmware answers, or it
    /// stops.
    ///
    /// Some loaders restart into the new firmware without asking to finish, on an endpoint that
    /// may or may not show as lost. So once nearly all of the application area has been read, the
    /// firmware answering counts as finished: while the loader is quiet, or after the connection
    /// is lost, unless the loader answers again first. Which of a loader's passes writes the flash
    /// isn't known in advance: Felucca's reads the whole package once to check it and erases and
    /// writes in its second pass, while M-VAVE's writes in its only pass.
    func serveLoader(
        _ package: FwscPackage,
        from loader: FoundDevice,
        events: @escaping @Sendable (UpdateEvent) -> Void
    ) async throws -> ServeOutcome {
        var progress = WriteProgress(region: package.container.applicationRange)
        var outcome: ServeOutcome
        do {
            defer { loader.connection.close() }
            events(.loaderFound(loader.identity))
            try loader.connection.send(FM1Message.upgradeCommand)
            try await pause(timing.afterUpgradeCommand)
            outcome = try await serve(
                loader.connection,
                image: package.logicalImage,
                phase: .writing,
                idleLimit: timing.writeIdleLimit,
                lookingAfterQuiet: timing.returnCheckAfter,
                progress: { request, _ in events(progress.record(request)) },
                lookForReturn: {
                    // Some loaders restart without asking to finish, on an endpoint that never shows as lost.
                    guard progress.isNearlyWritten else { return nil }
                    let identity = package.identity
                    return try? await self.findOnly(where: { $0 == identity })
                }
            )
        }
        // The package's firmware counts only once nearly all of it has been read, so the old
        // firmware coming back under the same identity isn't taken for the new one.
        guard outcome.lost, progress.isNearlyWritten else { return outcome }
        let loaderIdentity = loader.identity
        let firmware = package.identity
        if let back = try await waitFor(timing.returnSearch, where: { $0 == loaderIdentity || $0 == firmware }) {
            if back.identity == firmware {
                outcome.returned = back
            } else {
                back.connection.close()
            }
        }
        return outcome
    }

    /// The device once it's running firmware again after writing, or the error that says why not.
    ///
    /// Besides a loader that asks to finish, a write counts as done when the package's firmware
    /// answered while the loader was quiet or once it came back.
    func returnedDevice(after writing: ServeOutcome, events: @Sendable (UpdateEvent) -> Void) async throws
        -> FoundDevice
    {
        if let returned = writing.returned {
            events(.rebooting)
            return returned
        }
        guard writing.finished else {
            throw writing.lost
                ? FM1UpdateError.disconnected(phase: .writing, requests: writing.requests)
                : FM1UpdateError.stalled(phase: .writing, requests: writing.requests)
        }
        events(.rebooting)
        try await Task.sleep(for: timing.firmwareBoot)
        guard let returned = try await waitFor(timing.returnSearch, where: { !$0.isLoader }) else {
            throw FM1UpdateError.deviceDidNotReturn
        }
        return returned
    }
}
