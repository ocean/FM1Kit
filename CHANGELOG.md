# Changelog

All notable changes to FM1Kit are recorded here. The project follows
[Semantic Versioning](https://semver.org); until 1.0, minor versions may change the API.

## [Unreleased]

### Added

- `FwscPackage`: reads `.fwsc` firmware packages, their product identity, logical image and SHA-256.
- `OfficialFirmware`: recognises M-VAVE's official releases (V15) by size and checksum.
- `FM1Identity`: parses what a device or package reports, including the `ota-` update loader.
- `FM1Updater`: installs a package over USB-MIDI, resumes an interrupted update or a device in
  USB recovery mode, and checks the device reports the new firmware afterwards.
- `CoreMIDITransport` for real devices on iOS and macOS, and `SimulatedFM1` for the iOS
  Simulator and tests.
- `fm1probe`, a Mac command-line tool that lists ports, identifies a connected FM-1 (repeatedly,
  with timings), monitors SysEx, watches devices come and go, inspects packages, and installs
  a firmware after asking to confirm (or rehearses one against `SimulatedFM1`).
- Installs and resumes support task cancellation.
- `FM1Identity` is `Codable` (as its text) and can be made from a model and version.
- `SimulatedFM1` refuses a package with the identity it's running, as the real device does.
- `UpdateEvent.checking(fraction:requests:)` reports a loader reading the image a second time
  after writing, as Felucca's loader does. `UpdateEvent.writing`'s fraction is the share of the
  firmware's application area read so far, in any order (V15's loader reads backwards), so
  both loaders seen reach 1. `SimulatedFM1.Options` can read backwards (`writesBackwards`) and
  check after writing (`checksAfterWriting`), as these loaders do.
- `FwscPackage` checks the JieLi container inside a package before anything is sent: the header
  and table checksums, the chip (AC791N), each part's checksum, and that there's one firmware
  image and one update loader. New `Failure` cases say what's wrong (`tooLarge`, `damagedHeader`,
  `unexpectedChip`, `damagedPart`, `missingPart`). `FwscPackage.loaderSHA256` identifies the
  loader a package brings, and `OfficialFirmware.stockLoaderSHA256` is M-VAVE's.
  `fm1probe inspect` shows both.
- `FM1UpdateError.unexpectedFinish(phase:)`: the update stops if the device asks to finish the
  other half of the update.

### Changed

- Updates add no pauses, as M-VAVE's own updater doesn't: `UpdaterTiming.responseDelay` and
  `afterUpgradeCommand` are now zero by default (were 10 ms and 2 s).
- After answering a finish request, the updater keeps the port open for
  `UpdaterTiming.finishSettle` (600 ms), answering any repeat, so the reply isn't cut off.
