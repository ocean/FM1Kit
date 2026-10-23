public import Foundation

// A sample m-bootloader and installer package for tests and apps that use SimulatedFM1. Their
// code is filler, so they must never be installed on a real FM-1.

@_spi(Testing)
extension BootloaderImage {
    /// A container that passes every check, carrying m-bootloader's marker.
    ///
    /// - Parameters:
    ///   - version: The version it reports.
    ///   - board: The board it names: ``fm1Board`` for the FM-1.
    /// - Returns: The container, as a `.boot` file holds it.
    public static func sample(version: String = "1.2-sample", board: String = fm1Board) -> Self {
        var code = (0..<512).map { UInt8(truncatingIfNeeded: $0 &* 29 &+ 3) }
        code.replaceSubrange(markerOffset..<(markerOffset + marker.count), with: marker)
        code.replaceSubrange(boardOffset..<versionOffset, with: padded(board, to: versionOffset - boardOffset))
        code.replaceSubrange(
            versionOffset..<(versionOffset + versionLength), with: padded(version, to: versionLength))
        var header =
            FM1Message.littleEndian(1, byteCount: 2) + FM1Message.littleEndian(UInt32(code.count), byteCount: 2)
        header += FM1Message.littleEndian(loadAddress, byteCount: 4) + FM1Message.littleEndian(16, byteCount: 4)
        header += FM1Message.littleEndian(UInt32(FirmwareContainer.crc16(code)), byteCount: 2)
        header += FM1Message.littleEndian(UInt32(FirmwareContainer.crc16(header)), byteCount: 2)
        guard let image = Self(bytes: header + code) else { preconditionFailure("The sample container checks out.") }
        return image
    }

    private static func padded(_ text: String, to length: Int) -> [UInt8] {
        let bytes = Array(text.utf8.prefix(length - 1))
        return bytes + [UInt8](repeating: 0, count: length - bytes.count)
    }
}

@_spi(Testing)
extension FwscPackage {
    /// Builds an m-bootloader installer package around a bootloader, as m-bootloader's release
    /// packages are built: only an `ota.bin`, holding the installer's compressed code, labelled
    /// `FM-1_099`.
    ///
    /// The installer's code is filler around the bootloader: never install it on a real FM-1.
    ///
    /// - Parameter bootloader: The bootloader the installer carries.
    /// - Returns: The `.fwsc` file's contents.
    public static func sampleBootloaderInstallerFile(carrying bootloader: BootloaderImage = .sample()) -> Data {
        let filler = (0..<700).map { UInt8(truncatingIfNeeded: $0 &* 11 &+ 1) }
        let stream = StagedUpdater.encode(filler + bootloader.bytes + filler)
        let image = sampleImage(parts: [.loader(size: stream.count)], contents: [0: stream])
        return Data(sampleFile(logicalImage: image, product: "FM-1_099"))
    }
}

extension StagedUpdater {
    /// Encodes code as a staged updater stream, in literal-only LZ4 blocks, for samples.
    static func encode(_ code: [UInt8]) -> [UInt8] {
        var blocks: [UInt8] = []
        for start in stride(from: 0, to: code.count, by: 2048) {
            let part = Array(code[start..<min(start + 2048, code.count)])
            var packed: [UInt8] = [UInt8(min(part.count, 15) << 4)]
            if part.count >= 15 {
                packed += [UInt8](repeating: 255, count: (part.count - 15) / 255) + [UInt8((part.count - 15) % 255)]
            }
            packed += part
            blocks += FM1Message.littleEndian(UInt32(packed.count), byteCount: 4)
            blocks += FM1Message.littleEndian(UInt32(part.count), byteCount: 4) + packed
        }
        let name = Array("usb_hid_ota.bin".utf8) + [0]
        var header = [0, 0] + FM1Message.littleEndian(UInt32(FirmwareContainer.crc16(code)), byteCount: 2)
        header += FM1Message.littleEndian(UInt32(code.count), byteCount: 4)
        header += FM1Message.littleEndian(loadAddress, byteCount: 4) + FM1Message.littleEndian(0, byteCount: 4) + name
        header.replaceSubrange(
            0..<2, with: FM1Message.littleEndian(UInt32(FirmwareContainer.crc16(header[2...])), byteCount: 2))
        let body = header + blocks
        var record = [0, 0] + FM1Message.littleEndian(UInt32(FirmwareContainer.crc16(body)), byteCount: 2)
        record += FM1Message.littleEndian(32, byteCount: 4) + FM1Message.littleEndian(UInt32(body.count), byteCount: 4)
        record += [0x41, 0, 0, 0] + name
        record.replaceSubrange(
            0..<2, with: FM1Message.littleEndian(UInt32(FirmwareContainer.crc16(record[2...])), byteCount: 2))
        return record + body
    }
}
