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
    /// DUB-1, Estampie, LOF-1, LOOM-8 and Felucca itself do.
    ///
    /// It's read from the firmware's code: Felucca's update code recognises its own loader by
    /// the text `FELUCCA-LOADER-1`, so it can't work without it. `false` for an installer
    /// package. Whether the firmware refuses V15 once m-bootloader is installed is
    /// ``refusesV15OverOtherBootloaders``.
    public var usesFeluccaUpdateCode: Bool {
        firmwareCode?.contains(Self.feluccaLoaderMarker) ?? false
    }

    /// True when the firmware, once running, refuses V15 over USB-MIDI if the FM-1's
    /// bootloader has been changed, by m-bootloader or by M-VAVE's open firmware.
    ///
    /// Felucca's original update check installs a package that brings M-VAVE's update loader
    /// (V15 or open firmware) only when the FM-1 already has the bootloader the package brings.
    /// Once the bootloader has been changed, such a firmware refuses V15
    /// (``FM1UpdateError/bootloaderMismatch(requests:)``), as well as m-bootloader's installer
    /// (``FM1UpdateError/packageRefused(requests:)``): it only installs other firmwares on
    /// Felucca's platform, and going back to V15 needs the chip's USB download mode, from a Mac.
    /// Apps can warn before installing such a firmware on an FM-1 whose bootloader may have
    /// been changed.
    ///
    /// Firmwares built on the fixed update code (felucca-bsp from October 2026, such as LOOM-8
    /// 0.8) only check that the package's bootloader is one the FM-1 can start, and take V15:
    /// their code holds that check's text `AC79BLID`. Firmwares that recognise V15 itself by
    /// the SHA-256 of its flash image, such as SikkenWorks' ETCH, BEETLE and B1, take V15
    /// whichever bootloader is installed, though not M-VAVE's open firmware: their code holds
    /// that hash. A firmware that installs every package with a loader of its own, as
    /// TransitFM1 does, takes V15 too, but isn't recognised. `false` for an installer package.
    public var refusesV15OverOtherBootloaders: Bool {
        guard let code = firmwareCode else { return false }
        return code.contains(Self.feluccaLoaderMarker) && !code.contains(Self.bootloaderCheckMarker)
            && !code.contains(Self.v15FlashImageSHA256)
    }

    /// The text Felucca's update code recognises its own loader by.
    static let feluccaLoaderMarker = Array("FELUCCA-LOADER-1".utf8)
    /// The text the fixed update code looks for in an m-bootloader container.
    static let bootloaderCheckMarker = Array("AC79BLID".utf8)
    /// The SHA-256 of V15's flash image, from address 0, as bytes.
    static let v15FlashImageSHA256 =
        FM1BuildID(knownHex: "c1068a403c04a6378a626afb66cc217f72d13f10aa200e983b7a9817cc1dac03").bytes

    /// The firmware's `app.bin`, deciphered, or `nil` for an installer package.
    private var firmwareCode: [UInt8]? {
        flashImage.flatMap { ApplicationArea(flash: $0, chipKey: ApplicationArea.fm1ChipKey).code() }
    }
}

extension [UInt8] {
    fileprivate func contains(_ text: [UInt8]) -> Bool {
        firstRange(of: text) != nil
    }
}
