import os

/// The simulated FM-1's bootloader: M-VAVE's, or m-bootloader once an installer has run.
extension SimulatedFM1 {
    /// Runs a staged installer as the bootloader does: an m-bootloader installer rewrites the
    /// boot area, and either way the FM-1 restarts into the firmware it was running.
    func runInstaller(_ package: FwscPackage) async {
        guard case .firmware(let running) = state.withLock({ $0.mode }) else { return }
        if let installer = try? BootloaderInstaller(package: package) {
            state.withLock { $0.bootloaderVersion = installer.bootloader.version }
            log("Installed m-bootloader \(installer.bootloader.version); restarting into \(running.text).")
        } else {
            log("The installer isn't m-bootloader's; restarting into \(running.text).")
        }
        await reboot(into: .firmware(running))
    }
}
