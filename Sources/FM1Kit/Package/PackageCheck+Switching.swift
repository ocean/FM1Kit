// Which firmwares install a package, and how people switch away from it.
extension PackageCheck {
    static func installing(_ package: FwscPackage) -> [Finding] {
        let loader: String
        let feluccaOriginal: Finding
        switch package.updateLoader {
        case .feluccas:
            loader = "Felucca's update loader"
            feluccaOriginal = Finding(
                topic: .installing,
                outcome: .pass,
                summary:
                    "Firmwares with Felucca's original update check (Felucca, AMB-1, DUB-1 and others) will install it."
            )
        case .mVaves:
            loader = "M-VAVE's update loader"
            // M-VAVE's own packages can't change, so it's only worth knowing for them.
            feluccaOriginal = Finding(
                topic: .installing,
                outcome: OfficialFirmware.matching(package) == nil ? .warning : .note,
                summary: """
                    Firmwares with Felucca's original update check install it only when the FM-1's bootloader \
                    matches the package's boot area byte for byte, so not after m-bootloader or V16. Those with \
                    the fixed check (MIDIMON 0.4, LOOM-8) take it.
                    """)
        case .other:
            loader = "an update loader FM1Kit doesn't recognise"
            feluccaOriginal = Finding(
                topic: .installing,
                outcome: .warning,
                summary: """
                    Firmwares with Felucca's original update check accept only M-VAVE's loader or Felucca's, so \
                    they'll refuse it. Those with the fixed check (MIDIMON 0.4, LOOM-8) take it.
                    """)
        }
        return [
            Finding(
                topic: .installing,
                outcome: .pass,
                summary: "It brings \(loader). V15, V16 and M-VAVE's open firmware install any package."),
            feluccaOriginal,
        ]
    }

    static func leaving(_ package: FwscPackage) -> [Finding] {
        guard let stock = LeavingGuide(package: package, bootArea: .v15),
            let mBootloader = LeavingGuide(package: package, bootArea: .mBootloader)
        else {
            return []
        }
        let updateCode: String =
            switch stock.updateCode {
            case .mVave: "M-VAVE's update code"
            case .feluccaFixedCheck: "Felucca's fixed update check"
            case .feluccaOriginalCheck: "Felucca's original update check"
            case .recognisesV15: "Felucca's original update check, recognising V15"
            case .ownLoader: "a loader of its own for every package"
            case .unknown: "update code FM1Kit doesn't recognise"
            }
        var findings = [
            Finding(
                topic: .leaving,
                outcome: .note,
                summary: "Once installed, it installs other firmwares with \(updateCode).")
        ]
        let remedy =
            stock.updateCode == .ownLoader
            ? "Its own loader takes only images the size of V15's."
            : "Felucca's fixed update check (felucca-bsp from October 2026) avoids this."
        for (guide, bootloader) in [(stock, "V15's bootloader"), (mBootloader, "m-bootloader")] {
            let routes = [LeavingDestination.v15, .v16].map { destination in
                (destination, guide.route(to: destination))
            }
            let blocked = routes.filter { $0.1 == .throughFixedFirmware }.map { $0.0 == .v15 ? "V15" : "V16" }
            let unsure = routes.filter { $0.1 == .uncertain }.map { $0.0 == .v15 ? "V15" : "V16" }
            if !blocked.isEmpty {
                findings.append(
                    Finding(
                        topic: .leaving,
                        outcome: .warning,
                        summary: """
                            With \(bootloader), it can't install \(blocked.joined(separator: " or ")) directly: going \
                            back takes MIDIMON 0.5 first, or download mode from a Mac. \(remedy)
                            """))
            } else if !unsure.isEmpty {
                findings.append(
                    Finding(
                        topic: .leaving,
                        outcome: .note,
                        summary:
                            "With \(bootloader), whether it installs \(unsure.joined(separator: " or ")) isn't known."))
            } else {
                findings.append(
                    Finding(
                        topic: .leaving,
                        outcome: .pass,
                        summary: "With \(bootloader), it installs V15 and V16 directly."))
            }
        }
        return findings
    }
}

extension FwscPackage {
    /// Which update loader a package brings, as the update checks of other firmwares tell them apart.
    package enum UpdateLoader: Sendable, Hashable {
        /// M-VAVE's, as V15 and V16 bring.
        case mVaves
        /// Felucca's, recognised by the text `FELUCCA-LOADER-1`.
        case feluccas
        /// Another.
        case other
    }

    /// The update loader the package brings.
    package var updateLoader: UpdateLoader {
        if loaderSHA256 == OfficialFirmware.stockLoaderSHA256 { return .mVaves }
        let loader = Array(logicalImage[container.loader.range])
        return loader.contains(Self.feluccaLoaderMarker) ? .feluccas : .other
    }
}
