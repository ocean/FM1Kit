# Changelog

All notable changes to FM1Kit are recorded here. The project follows
[Semantic Versioning](https://semver.org); until 1.0, minor versions may change the API.

## [Unreleased]

### Added

- `FlashPlan.installingWithTransporter(_:onto:flashID:)` and `FlashPlan.transporterWritable`:
  plans a firmware install for the [FM-1 Transporter](https://github.com/kurogedelic/FM-1-transporter),
  which reaches the chip's boot ROM when no firmware starts, against its backup of the FM-1. The
  plan's `target` is the full flash image its web app writes; a firmware reaching past
  0x92FFF, which it won't write, is refused with `FlashPlanError.outsideTransporterRange(_:)`.
- fm1probe's `flash-image FILE.fwsc BACKUP.bin IMAGE.bin [--flash-id HEX]` saves that image,
  talking to no device.
- `PackageCheck`: a pre-release report on a firmware package, read from the package alone.
  It checks that the image is enciphered for the FM-1's chip key with whole files, which flash
  chips its code checks for, and that its saved data is whole sectors clear of the image and of
  `0xFC000` onwards. It also says which firmwares will install it, by the update loader it brings,
  how people can switch from it to V15 and V16 with V15's bootloader or m-bootloader, and whether
  the FM-1 Transporter can put it back. fm1probe's `check FILE.fwsc [--strict]` prints it and
  exits with 1 on a failure, or on a warning with `--strict`.
- fm1probe's `devices`, `identify`, `inspect` and `check` take `--json`: one JSON object on
  standard output, whose `format` names its layout and version (`fm1probe-devices-1`,
  `fm1probe-identify-1`, `fm1probe-inspect-1`, `fm1probe-check-1`). Fields that aren't known are
  left out, and anything else goes to standard error.

## [0.6.0] - 2026-11-07

FM1Kit knows the newer flash chip in FM-1s sold since autumn 2026, and asks firmwares built on
felucca-bsp for their whole identity. An install finishes when the new firmware answers, even
if the loader never asked to finish, and an interrupted write now tells people not to switch
the FM-1 off. Installs, m-bootloader over V15's and V16's boot areas and `--wait` were tried on
an FM-1 with the first chip (stages T to X), with the extra identity query in every install.
Not yet seen on hardware: an FM-1 with the newer chip, a firmware that shortens its identity, and
a loader that restarts without asking to finish.

To move from 0.5: `InstallProgress.Stage.checking` is gone (the second pass counts as
`installing`). `UpdateEvent.checking` is unchanged, but it's the loader's second pass, in which
Felucca's loader writes: show it as installing, not checking. Use `.upToNextMinor(from: "0.6.0")`.

### Added

- `MIDIPortDescriptor.usbProductName`: the name the USB device reports for itself now, read from
  IOKit on macOS (`nil` on iOS). macOS keeps the name it first saw for a device's USB IDs and
  socket, so after switching to a firmware that shares another's IDs, as CLEANSWEEP and ESTAMPIE
  do, `name` can still be the old firmware's.
- `FM1Updater.isProbeable(_:)` also matches the USB device's own name.
- fm1probe's `ports`, `identify` and `devices` show the USB device's own name when macOS still
  shows an older one, such as "FM-1 CLEANSWEEP (macOS still calls it FM-1 ESTAMPIE)", and
  `identify --port NAME` matches either name.
- `USBDownloadModeConnection.open(waitingUpTo:)` waits for an FM-1 to appear in download mode
  and captures it at once, looking every 20 ms. It's for an FM-1 whose firmware crashes at
  start-up and passes through download mode by itself, only for a few seconds each time.
  fm1probe's `flash-` commands take `--wait SECONDS` for it.
- `FM1FlashChip`: the FM-1's flash chips, the first units' P25Q80 (0x856014) and the UC25HQ80
  (0xB36014) of those sold since autumn 2026. Firmwares that only know the first keep saves on
  the newer one only until it's switched off, and often can't take an update.
- `FM1Identity.flashChipID(inHandshakeReply:)`, `FoundDevice.flashChipID`, and
  `FM1DeviceSummary.flashChipID` and `hasNewerFlashChip`: the flash chip, as
  firmwares built on felucca-bsp since November 2026 report it in the handshake reply
  (Felucca#320), such as ESTAMPIE; `nil` from others. fm1probe's `identify` shows it, and the
  `flash-` commands say when an FM-1 has the newer chip.
- `FwscPackage.flashChipSupport` (`FlashChipSupport`): which flash chips a firmware's code
  checks for, from the 32-bit constants it holds: both (`bothChips`), the first FM-1s' alone
  (`firstChipOnly`, which on the newer chip usually keeps saves only until switched off), or
  neither (`noCheck`, as V15). fm1probe's `inspect` shows it. Every fixed firmware seen so far
  holds both IDs. V16 names the first chip and another, but not the newer one; whether it saves
  on the newer chip isn't known.
- `FM1Message.fullIdentityQuery`: firmwares built on felucca-bsp since November 2026 answer the
  handshake with their identity cut to its name, '_' and three digits, such as `FM-1_123` for
  `FM-1_1234567`, because M-UPGRADE 3.11 refuses longer ones, and give the whole identity when
  asked with this. FM1Updater asks after a three-digit answer, and after any answer that carried
  no flash chip, for firmwares that report it only when asked (not V15's or V16's, nor the
  loader's), waiting `UpdaterTiming.fullIdentityWait` (300 ms) for firmwares that don't answer
  it. So these firmwares are named, checked and confirmed after an install by their whole
  identity, and their flash chip is known either way.
- `FlashPlan.installing(_:onto:)` warns before installing m-bootloader on the newer flash chip,
  on which it has hardly been tried, and refuses a version that would stop at `BAD CONFIG` on
  every start: before 1.3 with V16's boot configuration, before 2.0 with one m-bootloader 2 has
  shortened (`FlashPlanError.bootloaderTooOld(_:minimum:)`).

### Changed

- `FlashSession.write(_:progress:)` works from the top of the flash down, so a firmware's
  start-up code is the last thing replaced. A firmware whose start-up code brings the FM-1 back
  to download mode by itself still does that if writing stops part-way.
- `FlashPlan.installingBootloader(from:onto:)` writes the package's whole boot area, its boot
  configuration included, as an official update does, instead of keeping the FM-1's. M-VAVE's
  bootloader reads the configuration, which m-bootloader 2 shortens, and V16's differs from
  V15's.

### Fixed

- The errors for an update interrupted while writing say to keep the FM-1 switched on and
  resume, as its screen stays dark while it updates and it may not start again until the update
  is finished, rather than that it stays in update mode until one finishes. On an FM-1 (stage
  W3), Felucca's loader answered again 12 s after the cable went back in; with its screen dark,
  the FM-1 was then switched off, and it no longer started. fm1probe's install warning says the
  same.
- `UpdateEvent.checking` and `InstallProgress` no longer present a loader's second pass as a
  check: Felucca's loader checks the package in its first pass and erases and writes in its
  second. `InstallProgress` reports it as `installing`, and `InstallProgress.Stage.checking` is
  removed. fm1probe calls it the second pass.
- An install finishes when the package's firmware answers after nearly all of the application
  area has been written and the loader has gone quiet (`UpdaterTiming.returnCheckAfter`, 5 s),
  or when the FM-1 goes away at that point and comes back running firmware, even if the loader
  never asked to finish. Before, an FM-1 that restarted into the new firmware without asking,
  as one installing AMB-1 did, could leave `install` waiting out `writeIdleLimit` and throwing
  `stalled(.writing)`, with the new firmware already playing. If it comes back in its loader,
  the error is still `disconnected(.writing)`, so the write can be resumed.
- fm1probe no longer goes quiet in a terminal that an earlier program left non-blocking, such
  as `screen` on a USB serial port that went away. It makes its output blocking again when it
  starts, and if any output was lost anyway, it says so and exits with an error.
- `FlashPlan` takes the newer flash chip as an FM-1's when the flash doesn't show the model, as
  with broken firmware, instead of refusing to restore or install.
- `FlashPlan.installing(_:onto:)` installs m-bootloader on an FM-1 with V16's boot area, whose
  configuration starts after V16's larger bootloader, and on one where m-bootloader 2 shortened
  it, instead of saying the boot area can't be read.

## [0.5.1] - 2026-11-03

TransitFM1 refuses V16, as tested on an FM-1 in stage S, so the switching guide now sends people
from it to V16 through MIDIMON 0.4 or LOOM-8.

### Fixed

- `LeavingGuide` now sends people from TransitFM1 to V16 through MIDIMON 0.4 or LOOM-8:
  TransitFM1 refuses V16 at the header (tested on an FM-1 in stage S), since it takes only
  firmware images the size of V15's. Its steps to V16 no longer say the FM-1 keeps its bootloader,
  or that TransitFM1 must be confirmed as not V15.
- `packageRefused`'s explanation names TransitFM1, and says MIDIMON 0.4 and LOOM-8 take V16 too.
- `fm1probe install --reinstall-official` describes the install by the package's identity, since
  it can't tell whether TransitFM1 is being installed over V15 or V15 over TransitFM1.

## [0.5.0] - 2026-11-02

M-VAVE's V16, a guide to switching away from each firmware, and a fresh start that clears every
firmware's saved data, all tested on an FM-1 in stage R. It also includes 0.5.0-beta.1's choice of
device, which has been tested only with simulated devices so far.

### Added

- `LeavingGuide`: how to switch away from a firmware, worked out from its package before it's
  installed. `FwscPackage.updateCode` reads how the firmware installs others (`UpdateCode`: M-VAVE's,
  Felucca's original or fixed check, V15 recognised by hash, or a loader of its own), and the guide
  combines it with the FM-1's bootloader (`FM1BootArea`) to give a `LeavingRoute` to V15, V16, open
  firmware, other custom firmwares and m-bootloader, `warnings` to show before installing, and
  step-by-step `instructions(to:)`. It's `Codable`, so apps can save it with the FM-1, which also
  tells TransitFM1 apart from V15. `refusesV15OverOtherBootloaders` is now `updateCode ==
  .feluccaOriginalCheck`. Stage R confirmed its routes to and from V16 on hardware.
- `OfficialFirmware.v16`: M-VAVE's V16 (`FM-1_016`), which their downloads page has served since
  21 October 2026, with `FM1Identity.officialV16` and `FM1Identity.isOfficial`. `OfficialFirmware`
  gains `identity`, `isRedistributable` (only V15 may be included in an app; download V16 from
  M-VAVE) and `official` (V15 and V16). `FM1DeviceSummary` names V16, and V16 over V16 is a
  `reinstall`, as for V15. Tested on hardware in stage R.
- `FlashBackup.firmware` names V16 ("V16 (FM-1_016)") by its `app.bin`'s SHA-256, as read from
  a real FM-1, instead of "unknown, naming FM-1_016".
- `InstallOptions.confirmsReinstallingOfficial` and `InstallCheck.canReinstallOfficial`:
  installing M-VAVE's official firmware (V15) on an FM-1 that reports its identity, once the
  person confirms it's running a firmware that reports it on purpose, such as TransitFM1.
  Without it, FM1Kit couldn't take an FM-1 from TransitFM1 back to V15. `alreadyInstalled` for
  V15 now says so, and its advice is `confirm`.
  `fm1probe install --reinstall-official` does the same.

### Changed

- `FlashPlan.installing(_:onto:includingBootloader:erasingSettings:)` is now
  `installing(_:onto:includingBootloader:erasingSavedData:)`, and erases more: everything from
  the end of the new image up to `0xFBFFF`, which covers every saved-data region firmwares
  declare (`VM`, `BTIF`, V15's voice banks in `USR`, V16's `SEQ64`) and what they leave outside
  them, so the new firmware starts from its defaults instead of meeting another firmware's
  leftovers. V16 leaves data in V15's `USR` region that makes V15 play one note at a time, which
  only this clears (tested on hardware, stage R). It never touches the boot area, `0xFC000`
  onwards or the factory data. Installing V15 this way writes its factory voices and the rest of
  its `USR` data straight back into the erased voice banks, so it's never silent and needs no
  voice restore. `fm1probe flash-install --erase-settings` is now `--erase-saved-data`.
- `bootloaderMismatch` and `refusesV15OverOtherBootloaders` explain that V16 brings a different
  bootloader from V15, so firmwares with Felucca's original check refuse V16 on an FM-1 with
  V15's bootloader, and V15 once V16's is installed.
- `packageRefused` says firmwares based on Felucca 1.6.1 refuse V16 as well as open firmware,
  whatever the bootloader (stage R). `bootloaderMismatch` no longer says download mode keeps the
  FM-1's bootloader: after V16, V15 is installed there with its own bootloader, fresh.
- `bootloaderMismatch` and `packageRefused` name MIDIMON 0.4 as well as LOOM-8 as the firmware
  to install first, and put that before download mode: a firmware with Felucca's original check
  takes either, and they take V15 and open firmware (tested on hardware). Their advice is now
  `chooseAnotherFirmware`, not `needsComputer`, since the way out works from a phone.
- `fm1probe inspect` suggests MIDIMON 0.4 or LOOM-8 for a firmware that refuses V15.

### Fixed

- `DownloadModeError.accessRefused` promised that macOS would ask to allow access to a
  removable volume. macOS asks only a program in the logged-in person's session; a launchd
  helper is refused without being asked, whatever its Full Disk Access.
- `refusesV15OverOtherBootloaders` was true for Quixotic7's TransitFM1 and RemoteFM1. They
  install every package with a loader of their own, with no boot-area compare, so they take V15
  whatever the bootloader (though not open firmware).

## [0.5.0-beta.1] - 2026-10-28

A pre-release for testing with more than one device connected.

### Added

- Choosing a device when more than one is connected: `FM1Updater.devices()` lists every device
  that answers the handshake, and `FM1Updater(transport:timing:device:)` makes an updater that
  works with the chosen one alone. It leaves the other devices alone and follows the chosen one
  as it restarts into its update loader and back, on a new port. `FM1DeviceSummary` is
  `Identifiable` and has the `port` it answered on. `fm1probe devices` lists them, numbered,
  and `--device N|SERIAL` chooses one for `install`, `install-bootloader`, `restore-voices`,
  `backup` and `download-mode`.
- `FM1Advice.Action.chooseDevice`, the advice for `multipleDevices`, which was `reconnect`.

## [0.4.5] - 2026-10-28

### Fixed

- `refusesV15OverOtherBootloaders` was true for SikkenWorks' ETCH, BEETLE and B1. Their update
  code recognises V15 by its flash image's SHA-256 and takes it whatever the bootloader.

## [0.4.4] - 2026-10-27

### Added

- `FM1UpdateError.packageRefused(requests:)`: the firmware read the package's header and
  stopped, refusing it. Firmwares with Felucca's original update check do this for
  m-bootloader's installer and for update loaders they don't recognise, and copies of Felucca
  1.6.1 for M-VAVE's open firmware too (tested on hardware: `FAILED -15`). It was reported as
  `stalled(.staging)`, whose advice was to try again.
- `FM1Updater.installBootloader(_:fromAnyFirmware:events:)` and `fm1probe install-bootloader
  --from-any-firmware`: send m-bootloader's installer whatever firmware is running, for
  hardware tests of how other firmwares treat it.
- `SimulatedFM1.Options.refusesAfterHeader`.

### Changed

- `bootloaderMismatch` and `refusesV15OverOtherBootloaders` describe any changed bootloader,
  M-VAVE's open firmware's as well as m-bootloader (tested on hardware), and point to firmwares
  with Felucca's updated check as a way back. Estampie is no longer listed among the firmwares
  that refuse V15: its update code has the updated check.

### Fixed

- The README's and llms-full.txt's recovery sections describe download mode as FM1Rescue
  uses it.

## [0.4.3] - 2026-10-26

### Added

- `FwscPackage.refusesV15OverOtherBootloaders`: whether a firmware refuses V15 over USB-MIDI
  while m-bootloader is installed. Firmwares on the fixed update code of Felucca's platform
  (felucca-bsp from October 2026, such as LOOM-8 0.8, tested on hardware) take V15 and aren't
  flagged; `usesFeluccaUpdateCode` flagged them. `fm1probe inspect` tells the two apart.

## [0.4.2] - 2026-10-25

### Added

- `FwscPackage.usesFeluccaUpdateCode`: whether a firmware package's code uses Felucca's update
  code (AMB-1, HYP-1, DUB-1, Estampie, LOF-1, Felucca), which refuses V15 over USB-MIDI while
  m-bootloader is installed, so apps can warn before installing one. `fm1probe inspect` shows it.
  Reading a package's firmware code moved from FM1Rescue into FM1Kit, so it works on iOS too.

## [0.4.1] - 2026-10-25

### Added

- `FM1UpdateError.bootloaderMismatch(requests:)`: firmwares built on Felucca's platform (AMB-1,
  HYP-1, DUB-1, Estampie) compare the boot area of a package with M-VAVE's update loader (V15,
  open firmware) with the FM-1's before installing it, so they refuse V15 while m-bootloader is
  installed. An install that stops on that comparison now says so, and that installing in
  download mode from a Mac keeps the FM-1's bootloader, instead of the general staging advice.
  `SimulatedFM1.Options.comparesBootArea` simulates it.

### Fixed

- Firmwares numbering their builds `FM-1_8` and six digits, as DUB-1 does (`FM-1_8010300` for
  1.3.0), were taken for M-VAVE's open firmware, so installing over them stopped with
  `capabilityUnavailable`. `FM1Identity.isOpenFirmware` now takes `FM-1_8000000` to
  `FM-1_8000999` (and `FM1_COMMUNITY_`).
- `FlashBackup.firmware.name` names a custom firmware only when its code also holds the name and
  version it shows, as forks share identities: HYP-1 numbers its builds as AMB-1 does, so a HYP-1
  build could be named "AMB-1 1.3".
- `FlashPlan.installing(_:onto:includingBootloader:erasingSettings:)` no longer warns that the
  installed firmware keeps its settings elsewhere when it erases the new firmware's settings.
- fm1probe's timestamps were on a 12-hour clock without AM or PM when run under sudo; they're
  always 24-hour now.

## [0.4.0] - 2026-10-25

### Added

- `FM1Updater.installBootloader(_:events:)` installs m-bootloader from its `fm1-uboot.fwsc`
  package on an FM-1 running V15, keeping the firmware. `BootloaderInstaller` reads the package,
  decompresses its installer and checks every checksum, as the bootloader does before running
  it, and finds the bootloader it writes; `BootloaderImage` reads and checks m-bootloader's
  `.boot` files. FM1Kit can't read the bootloader back over USB-MIDI, so the FM-1's screen
  confirms the result.
- `FwscPackage.isFirmware`: packages that hold only an installer are now read, and
  `install`, `resume` and `check` refuse them (`FM1UpdateError.notFirmware`).
- `InstallProgress`: an install's events as one bar that never goes backwards, with four stages.
- `FM1Advice` (and `FM1UpdateError.advice`): any error as a headline, an explanation, whether
  the FM-1 is still fine, one action and technical details.
- `FM1Updater.summary()` and `FM1DeviceSummary`: the connected FM-1's firmware name and version
  (for V15 and open firmware), whether it's waiting mid-update, and its USB serial number
  (`MIDIPortDescriptor.serialNumber`).
- `SimulatedFM1` reports a serial number and runs bootloader installers
  (`Options.serialNumber`, `bootloaderVersion`; `installedBootloaderVersion`), and installing
  V15 on it puts M-VAVE's bootloader back, as on a real FM-1.
- `fm1probe install-bootloader`, `inspect` for installers and `.boot` files, and serial numbers
  in `identify`.
- A second library, `FM1Rescue` (macOS only; empty on iOS), for the chip's USB download mode:
  `FM1Updater.enterDownloadMode()` asks V15 or Felucca to switch with a MIDI message;
  `USBDownloadModeConnection` takes the FM-1 from macOS's disk driver (needs root) and speaks USB
  mass storage to it; `FlashSession` uploads m-bootloader's flash loader (bundled, MIT) and
  reads the flash; `FlashSession.backUp(progress:)` reads it twice and checks both reads against
  the chip's CRC-32; `FlashBackup.write(to:)` saves it as M-Flasher does.
  `SimulatedDownloadMode` stands in for the chip.
- `FlashBackup.firmware` says whether the firmware's files in a backup are whole (as
  m-bootloader's menu reports them), which identities its code names and whether it's V15, naming
  Felucca 1.6.1 and AMB-1 1.3 too (`name`), and the backup's `.json` gains M-Flasher's `firmware` and `app` fields.
  `FlashBackup(contentsOf:)` reads a saved backup.
- Writing in download mode, which works whatever the firmware: `FlashPlan` works out a change
  against the flash just read (`restoring(_:onto:)` a backup, `installing(_:onto:)` m-bootloader,
  `installingBootloader(from:onto:)` M-VAVE's bootloader from a firmware package, or
  `installing(_:onto:includingBootloader:erasingSettings:)` a firmware), listing the 4 KB
  sectors that change. `FlashSession.write(_:progress:)` checks the flash hasn't changed, erases
  and writes only those sectors, checks each run against the chip's CRC-32 and shows progress
  on the FM-1's screen. Another FM-1's backup never replaces this one's factory data, and
  nothing is planned for flash that shows it's another model's (`FlashBackup.model`; the
  SMK-37 has the same chip). If writing stops part-way, the error says not to switch the FM-1
  off but to restore the backup. New errors: `FlashPlanError`, and
  `DownloadModeError.flashChanged`, `writeNotVerified(_:)` and `writeInterrupted(at:_:)`.
  `SimulatedDownloadMode` erases and writes as NOR flash does.
- `fm1probe download-mode` and `fm1probe flash-backup FOLDER`, with `--trace` to print every USB
  transfer; `fm1probe inspect` shows the bootloader and firmware in a `.bin` backup;
  `fm1probe flash-restore`, `flash-bootloader` and `flash-install` write in download mode after
  saving a backup and asking to confirm, or rehearse with `--simulated BACKUP.bin`.

### Changed

- When an install stops before the FM-1 restarts, the error explains that a custom firmware's
  own update code may have refused the package, and that replacing it needs download mode.
- `fm1probe install-bootloader` shows staging progress as a count of requests.

### Fixed

- An install could wait forever when the FM-1 stopped asking for data but kept sending other
  SysEx: only read requests now count as activity, so it stops as stalled after the idle limit.

## [0.3.0] - 2026-10-23

### Added

- `FM1Updater.backUpOpenFirmware(progress:)` backs up an FM-1 running M-VAVE's open firmware:
  its 16 project slots, the project being edited (with unsaved changes) and its sample bank,
  through the firmware's project library. Open firmware can only read the project being
  edited, so each slot is loaded in turn and the workspace is put back afterwards; no slot is
  saved and the sample bank isn't written. `OpenFirmwareBackup.write(to:)` saves the backup as
  the `.fm1` project and `.fm1s` sample files M-VAVE's workbench restores, with a
  `backup.json` describing them. Open V13's per-slot tuning tables aren't included yet.
- `fm1probe backup FOLDER` (with `--simulated` and `--log FILE`).
- `SimulatedFM1` answers the project library while running open firmware
  (`Options.projectSlots`, `workspace`, `currentSlot`, `sampleBank`).
- `llms.txt` and `llms-full.txt` describe the package for language models; FM1Kit's page on
  fm-1.drewr.dev publishes them from each release.

### Fixed

- `SimulatedFM1` could ignore the upgrade command from a host that found its loader very
  quickly after staging, which made an open firmware test fail now and then.

## [0.2.0] - 2026-10-19

### Changed

- Installing the identity a custom firmware already reports is no longer refused. Felucca's update
  code, which Estampie inherits, doesn't compare identities, and firmwares that keep one identity
  across releases are updated this way. The new `InstallKind.sameIdentity` needs confirming with
  `InstallOptions.confirmsSameIdentity` (otherwise `FM1UpdateError.sameIdentityNotConfirmed`).
  Only V15 over itself is still refused as `reinstall` (`alreadyInstalled`), and open firmware
  still compares builds. `SimulatedFM1.Options.refusesRunningFirmware` now applies only to V15.
  The new `InstallKind` case means exhaustive switches over it need updating. Tested on hardware
  by installing Estampie 0.1 (`FM-1_378001`) over itself.

## [0.1.0] - 2026-10-17

The first release.

### Added

- `FwscPackage`: reads `.fwsc` firmware packages, their product identity, logical image and SHA-256.
- `OfficialFirmware`: recognises M-VAVE's official releases (V15, and Open V12) by size and checksum.
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
- M-VAVE's open firmware (`FM-1_8000012` and builds of it, `FM1Identity.isOpenFirmware`):
  the updater asks it for its `FM1Capability` and arms it with the package's `FM1BuildID`
  before the upgrade command, and checks the build it reports afterwards. New errors:
  `capabilityUnavailable`, `deviceBusy`, `armRefused(code:)` and `buildMismatch`.
  `OfficialFirmware` gains `buildID` and recognises Open V12 (`openV12`). `SimulatedFM1`
  simulates open firmware. Tested on one FM-1: installing Open V12 over V15, and arming it to
  install V15 back.
- `FM1Updater.check(_:buildID:)` says what an install would do (`InstallKind`: an update, a
  switch to a different firmware, or a reinstall) without changing the device.
  `install(_:options:events:)` takes `InstallOptions`; switching firmware, which can erase
  projects and samples, throws `switchNotConfirmed` unless `confirmsSwitchingFirmware` is set,
  and reinstalling the running firmware throws `alreadyInstalled` before anything is sent.
- Installs and resumes refuse to start while more than one FM-1 answers (`multipleDevices`).
  `FM1Updater.findAll(where:)` lists every device that answers.
- The updater also probes ports named after other firmwares' loaders: SLOOP, Clipper and SINCO.
- `@_spi(Testing)` `FwscPackage.sampleFile(product:flashSize:loaderSize:seed:)` builds a small
  valid package for apps' tests with `SimulatedFM1`. Never install one on a real FM-1.
- `FM1Identity` reads the identity an armed open firmware's update loader reports, such as
  `ota-FM1C_db1642b2b6fa5c2c` (`armedBuildPrefix`), so the updater finds that loader; an install
  checks it names the build it was armed with.
- `FM1Updater.restoreFactoryVoices(from:progress:)` rewrites V15's four voice banks with its 128
  factory voices from the official V15 package, as M-VAVE's updater does after installing V15
  (`FwscPackage.hasFactoryVoices`, `FM1Identity.officialV15`). New errors:
  `factoryVoicesUnavailable`, `voiceRestoreNeedsV15`, `voiceRestoreRefused` and
  `voiceRestoreStalled`. `SimulatedFM1` simulates V15's voice banks (`currentVoices`), and
  `fm1probe restore-voices` runs a restore after asking to confirm. Tested on one FM-1.
- Updates add no pauses, as M-VAVE's own updater doesn't: the device asks for each block when
  it's ready (`UpdaterTiming.responseDelay` and `afterUpgradeCommand` are zero by default).
- After answering a finish request, the updater keeps the port open for
  `UpdaterTiming.finishSettle` (600 ms), answering any repeat, so the reply isn't cut off.
- `fm1probe install` shows what the install would do and warns before switching firmware, and
  takes `--build-id`; `fm1probe identify` warns when more than one FM-1 answers.

[Unreleased]: https://github.com/ocean/FM1Kit/compare/0.6.0...HEAD
[0.6.0]: https://github.com/ocean/FM1Kit/compare/0.5.1...0.6.0
[0.5.1]: https://github.com/ocean/FM1Kit/compare/0.5.0...0.5.1
[0.5.0]: https://github.com/ocean/FM1Kit/compare/0.5.0-beta.1...0.5.0
[0.5.0-beta.1]: https://github.com/ocean/FM1Kit/compare/0.4.5...0.5.0-beta.1
[0.4.5]: https://github.com/ocean/FM1Kit/compare/0.4.4...0.4.5
[0.4.4]: https://github.com/ocean/FM1Kit/compare/0.4.3...0.4.4
[0.4.3]: https://github.com/ocean/FM1Kit/compare/0.4.2...0.4.3
[0.4.2]: https://github.com/ocean/FM1Kit/compare/0.4.1...0.4.2
[0.4.1]: https://github.com/ocean/FM1Kit/compare/0.4.0...0.4.1
[0.4.0]: https://github.com/ocean/FM1Kit/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/ocean/FM1Kit/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/ocean/FM1Kit/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ocean/FM1Kit/releases/tag/0.1.0
