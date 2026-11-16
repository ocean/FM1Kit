import os

/// The simulated FM-1's update loader writing a package.
extension SimulatedFM1 {
    /// Reads the whole package (in the order the options say, and twice if checking), then
    /// restarts running it.
    func write(_ package: FwscPackage, on connection: SimulatedConnection) async {
        let image = package.logicalImage
        var addresses = Array(stride(from: 0, to: image.count, by: options.writeChunkLength))
        let resources = package.resources
        // A loader leaving the resources reads only their header: the part's first 512 bytes.
        let leftOut = package.container.resources.flatMap { part in
            options.loaderLeavesResources
                ? (part.range.lowerBound + FM1Message.maximumReadLength)..<part.range.upperBound : nil
        }
        if let leftOut { addresses.removeAll { leftOut.contains($0) } }
        if options.writesBackwards {
            addresses.reverse()
        }
        let passes = options.checksAfterWriting ? [addresses, addresses] : [addresses]
        for pass in passes {
            for (index, address) in pass.enumerated() {
                if let unplugAt = options.unplugDuringWriteAt,
                    Double(index) / Double(pass.count) >= unplugAt,
                    !state.withLock({ $0.hasUnpluggedOnce })
                {
                    state.withLock { $0.hasUnpluggedOnce = true }
                    log("Cable pulled at \(Int(unplugAt * 100))%; the loader stays in update mode.")
                    await reboot(into: .loader)
                    return
                }
                var length = min(options.writeChunkLength, image.count - address)
                if let leftOut, address < leftOut.lowerBound { length = min(length, leftOut.lowerBound - address) }
                let request = FM1ReadRequest(address: UInt32(address), length: length)
                let expected = Array(image[address..<(address + length)])
                guard await exchange(request, expecting: expected, on: connection) else {
                    return
                }
            }
        }
        if !options.restartsWithoutFinishing {
            let finish = FM1ReadRequest(address: FM1Message.writeFinishAddress, length: 8)
            guard await exchange(finish, expecting: FM1Message.finishPayload, on: connection) else { return }
        }
        log("Wrote \(package.product); rebooting.")
        // Real open firmware reports the build compiled into it: here, the one it was armed with, or
        // else the build ID FM1Kit knows for the package.
        let packageBuildID = FM1Updater.knownBuildID(of: package) ?? FM1BuildID(knownHex: package.sha256)
        state.withLock { state in
            state.buildID = state.armedBuildID ?? packageBuildID
            state.buildResources = resources
            if let resources, !options.loaderLeavesResources { state.resources = Array(resources.payload) }
            // V15's package writes the whole boot area, putting M-VAVE's bootloader back.
            if package.identity == .officialV15 { state.bootloaderVersion = nil }
        }
        await reboot(into: .firmware(package.identity))
    }
}
