// The app area's layout and the per-block cipher follow M-Flasher's `formats.rs`
// (https://github.com/jvitkauskas/m-flasher), ported to Swift.
//
// MIT License, Copyright (c) 2026 Julius Vitkauskas
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
// and associated documentation files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import Foundation

/// The application area of FM-1 flash, from `0x4000`: a table of files (such as the firmware's
/// `app.bin`) and the regions it declares, then the files, all enciphered in 32-byte blocks keyed
/// by the chip key and the block's offset.
///
/// It reads a firmware package's image as well as a flash backup, which both start at flash
/// address 0.
package struct ApplicationArea {
    /// Where the app area starts in flash, after the boot area.
    package static let start = 0x4000
    /// The attribute of a file in the table, rather than a region.
    package static let fileAttribute: UInt8 = 0x82
    /// The chip key FM-1 firmware is enciphered with.
    package static let fm1ChipKey: UInt16 = 0x980F

    /// An entry in the table.
    package struct Entry: Sendable, Hashable {
        /// The CRC-16 of the file's deciphered bytes.
        package let dataCRC: UInt16
        /// Where it starts: from the start of the app area for files, in flash for regions.
        package let address: Int
        package let length: Int
        package let attribute: UInt8
        package let name: String
    }

    /// Flash from address 0, such as a backup or a package's image.
    package let flash: [UInt8]
    package let chipKey: UInt16

    package init(flash: [UInt8], chipKey: UInt16) {
        self.flash = flash
        self.chipKey = chipKey
    }

    /// The table: its files and the regions it declares, up to the first entry whose checksum
    /// fails.
    package func table() -> [Entry] {
        var entries: [Entry] = []
        for index in 0..<16 {
            let raw = bytes(at: 32 * index, count: 32)
            guard raw.count == 32,
                FirmwareContainer.crc16(raw[2...]) == FirmwareContainer.integer(raw, at: 0, byteCount: 2)
            else { break }
            entries.append(
                Entry(
                    dataCRC: UInt16(FirmwareContainer.integer(raw, at: 2, byteCount: 2)),
                    address: FirmwareContainer.integer(raw, at: 4, byteCount: 4),
                    length: FirmwareContainer.integer(raw, at: 8, byteCount: 4),
                    attribute: raw[12],
                    name: String(bytes: raw[16...].prefix { $0 != 0 }, encoding: .ascii) ?? ""
                ))
        }
        return entries
    }

    /// The firmware's `app.bin`, deciphered, if the table names one inside the flash.
    package func code() -> [UInt8]? {
        guard let app = table().first(where: { $0.name == "app.bin" }),
            Self.start + app.address + app.length <= flash.count
        else {
            return nil
        }
        return bytes(at: app.address, count: app.length)
    }

    /// Deciphers bytes of the app area, from `offset` within it.
    package func bytes(at offset: Int, count: Int) -> [UInt8] {
        var plain: [UInt8] = []
        plain.reserveCapacity(count + 64)
        var block = offset - offset % 32
        while block < offset + count, Self.start + block + 32 <= flash.count {
            let start = Self.start + block
            plain += FirmwareContainer.decipher(
                flash[start..<(start + 32)], key: chipKey ^ UInt16(truncatingIfNeeded: block >> 2))
            block += 32
        }
        return Array(plain.dropFirst(offset % 32).prefix(count))
    }
}

extension FwscPackage {
    /// True when the firmware uses the update code of Felucca's platform, as AMB-1, HYP-1,
    /// DUB-1, Estampie, LOF-1 and Felucca itself do.
    ///
    /// Once running, such a firmware installs a package that brings M-VAVE's update loader (V15
    /// or open firmware) only when the FM-1 already has the bootloader the package brings. With
    /// m-bootloader installed it refuses V15
    /// (``FM1UpdateError/bootloaderMismatch(requests:)``), and going back to V15 needs the
    /// chip's USB download mode, from a Mac. Apps can warn before installing such a firmware on
    /// an FM-1 that might have m-bootloader.
    ///
    /// It's read from the firmware's code: Felucca's update code recognises its own loader by
    /// the text `FELUCCA-LOADER-1`, so it can't work without it. A firmware could keep that and
    /// drop the check, but none seen so far does. `false` for an installer package.
    public var usesFeluccaUpdateCode: Bool {
        guard let image = flashImage,
            let code = ApplicationArea(flash: image, chipKey: ApplicationArea.fm1ChipKey).code()
        else {
            return false
        }
        return code.firstRange(of: Array("FELUCCA-LOADER-1".utf8)) != nil
    }
}
