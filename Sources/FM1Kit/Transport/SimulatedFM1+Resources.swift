import os

/// The simulated FM-1 taking a firmware's resources over USB-MIDI, as fm1-base firmwares built with
/// resources do.
extension SimulatedFM1 {
    /// Answers a request to take resources: refuses another build's, answers at once when it holds
    /// them already, and otherwise erases the region, reads the payload 512 bytes at a time,
    /// checks it and reports.
    ///
    /// A firmware without ``Options/buildResources`` ignores the request.
    func handleResourceRequest(_ payload: [UInt8], from connection: SimulatedConnection) {
        guard let build = options.buildResources, currentIdentity?.isLoader == false, payload.count == 8 else {
            log("The firmware ignores the resource request.")
            return
        }
        let length = Int(FM1Message.readLittleEndian(payload, at: 0, byteCount: 4))
        let crc = FM1Message.readLittleEndian(payload, at: 4, byteCount: 4)
        Task { [weak self] in
            guard let self else { return }
            if let code = options.resourceRefusal {
                await report(code: code, on: connection)
                return
            }
            guard length == build.payloadLength, crc == build.payloadCRC else {
                log("Another build's resources; refused.")
                await report(code: 20, on: connection)
                return
            }
            let expected = Array(build.payload)
            if state.withLock({ $0.resources }) == expected {
                log("The resources are there already.")
                await report(code: 0, on: connection)
                return
            }
            await take(expected, on: connection)
        }
    }

    /// Erases the region, asks first when told to, reads the payload and reports.
    private func take(_ expected: [UInt8], on connection: SimulatedConnection) async {
        let sectors = (ResourceRegion.headerLength + expected.count + 0xFFF) / 0x1000
        try? await Task.sleep(for: options.resourceSectorErase * sectors)
        if let pause = options.resourceAskPause {
            await report(address: FM1Updater.resourcesAskAddress, on: connection)
            try? await Task.sleep(for: pause)
        }
        let readLength = options.resourceReadLength
        for start in stride(from: 0, to: expected.count, by: readLength) {
            let data = expected[start..<min(start + readLength, expected.count)]
            let padded = Array(data) + [UInt8](repeating: 0, count: readLength - data.count)
            let request = FM1ReadRequest(address: UInt32(start), length: readLength)
            guard await exchange(request, expecting: padded, on: connection) else { return }
        }
        state.withLock { $0.resources = expected }
        log("Resources written (\(expected.count) bytes).")
        await report(code: 0, on: connection)
    }

    /// Reports the outcome with a read of the written or failed address, as fm1-base does.
    private func report(code: Int, on connection: SimulatedConnection) async {
        await report(
            address: code == 0 ? FM1Updater.resourcesWrittenAddress : FM1Updater.resourcesFailedAddress | UInt32(code),
            on: connection
        )
    }

    /// Makes one of the reads fm1-base uses to tell the host something.
    private func report(address: UInt32, on connection: SimulatedConnection) async {
        let request = FM1ReadRequest(address: address, length: FM1Message.finishPayload.count)
        _ = await exchange(request, expecting: FM1Message.finishPayload, on: connection)
    }
}
