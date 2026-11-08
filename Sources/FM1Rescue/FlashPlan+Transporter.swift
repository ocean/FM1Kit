#if os(macOS)
public import FM1Kit
import Foundation

extension FlashPlan {
    /// The flash the FM-1 Transporter writes: whole 4 KB sectors from `0x4000` to `0x92FFF`.
    ///
    /// Its firmware refuses anything else, so the boot area and saved data stay as they are.
    public static let transporterWritable = 0x4000..<0x9_3000

    /// Plans installing a firmware with the FM-1 Transporter, a Raspberry Pi RP2040 that reaches
    /// the chip's boot ROM when the FM-1's firmware can't start.
    ///
    /// The Transporter's web app writes a full flash image, and only the sectors in
    /// ``transporterWritable`` that differ from the FM-1's flash, after checking the flash still
    /// matches the backup it took. The plan's ``target`` is that image. Make it from the
    /// Transporter's own backup of the FM-1, taken in the same session, so everything outside the
    /// firmware is the FM-1's own.
    ///
    /// - Parameters:
    ///   - package: A firmware package for the FM-1.
    ///   - dump: The Transporter's backup of the FM-1.
    ///   - flashID: The flash chip's JEDEC ID as the Transporter reported it, for a backup saved
    ///     without a `.json` describing it.
    /// - Returns: The plan.
    /// - Throws: As ``installing(_:onto:includingBootloader:erasingSavedData:)``, or
    ///   ``FlashPlanError/outsideTransporterRange(_:)`` when the firmware reaches past what the
    ///   Transporter writes.
    public static func installingWithTransporter(
        _ package: FwscPackage,
        onto dump: FlashBackup,
        flashID: UInt32? = nil
    ) throws(FlashPlanError) -> Self {
        let current = flashID.map { id in
            FlashBackup(
                bytes: dump.bytes,
                uniqueID: dump.uniqueID,
                chipKey: dump.chipKey,
                flashID: id,
                loaderVersion: dump.loaderVersion,
                date: dump.date
            )
        }
        let plan = try installing(package, onto: current ?? dump)
        if let sector = plan.sectors.first(where: { !transporterWritable.contains($0) }) {
            throw .outsideTransporterRange(sector)
        }
        return plan
    }
}
#endif
