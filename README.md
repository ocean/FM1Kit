# FM1Kit

[![CI](https://github.com/ocean/FM1Kit/actions/workflows/ci.yml/badge.svg)](https://github.com/ocean/FM1Kit/actions/workflows/ci.yml)

A Swift package for installing firmware on the [M-VAVE FM-1](https://www.m-vave.com) over
USB-MIDI, from iOS and macOS.

FM1Kit speaks the FM-1's update protocol. It reads `.fwsc` firmware packages, finds the
device, answers its read requests while it stages and writes the new firmware, and checks
the device reports the new firmware afterwards. It can also finish an update that was cut off,
or one started from USB recovery mode.

> [!WARNING]
> FM1Kit has been tested on one FM-1 so far, from a Mac: installing M-VAVE's official V15,
> Felucca 1.6.1 and M-VAVE's open firmware V12 and switching between them, pulling the cable
> part-way through writing and resuming, restoring V15's factory voices, backing up open
> firmware, installing m-bootloader, and backing up, restoring and writing the whole flash in
> download mode. Reports from other devices and hosts are very welcome (see
> [CONTRIBUTING.md](CONTRIBUTING.md)).
> FM1Kit isn't affiliated with M-VAVE. Installing custom firmware is at your own risk.

## Requirements

- iOS 17 or macOS 14
- Swift 6.1 or later (Xcode 16.3 or later)
- An FM-1 connected by USB: an iPhone or iPad's USB-C port, a Lightning device through Apple's
  camera adapter, or a Mac

## Installation

Add FM1Kit with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/ocean/FM1Kit.git", .upToNextMinor(from: "0.4.1")),
]
```

Until 1.0, minor versions may change the API, so this takes 0.4.x fixes but not 0.5.0
(`from: "0.4.1"` would accept anything below 1.0). [CHANGELOG.md](CHANGELOG.md) lists the
changes.

## Usage

```swift
import FM1Kit
import Foundation

// Read a firmware package and see what it is.
let package = try FwscPackage(data: Data(contentsOf: fileURL))
print(package.product, package.sha256)

// Check what installing it would do. Switching to a different firmware can erase the
// FM-1's projects and samples, so it needs confirming once they're backed up.
let updater = FM1Updater(transport: try CoreMIDITransport(clientName: "My App"))
let check = try await updater.check(package)
let confirmed = check.kind != .switchingFirmware || askToSwitch(from: check.device)

// Install it on the connected FM-1.
let options = InstallOptions(confirmsSwitchingFirmware: confirmed)
try await updater.install(package, options: options) { event in
    switch event {
    case .staging(let requests): print("Preparing… \(requests)")
    case .writing(let fraction, _): print("Writing \(Int(fraction * 100))%")
    case .checking(let fraction, _): print("Checking \(Int(fraction * 100))%")
    case .finished(let identity): print("Now running \(identity)")
    default: break
    }
}

// Finish an update that was cut off, or one started in USB recovery mode.
if let identity = await updater.identify(), identity.isLoader {
    try await updater.resume(package)
}
```

Each firmware brings its own update loader, and loaders write differently. Writing progress
counts the firmware's application area, which every loader seen writes, whatever order it
reads in (V15's reads backwards). Some loaders then read it a second time, probably to check
it: Felucca's does, and FM1Kit reports that pass as `.checking`, so plan progress displays
for an optional second step.

Before installing, FM1Kit makes sure exactly one FM-1 answers, and won't reinstall V15 over
itself. It installs a different firmware, or the identity a custom firmware already reports
(a reinstall, or another release of a firmware that keeps one identity), only when told the
person updating has confirmed it, as M-VAVE's own updater does. It also speaks M-VAVE's open firmware's update
support (`FM-1_8000012` and builds of it), arming it with the package's build ID first.

After installing V15, `restoreFactoryVoices(from:progress:)` can rewrite its four voice banks
with the 128 factory voices from the V15 package, as M-VAVE's updater does: installing V15 over
custom firmware can leave a bank holding the old firmware's voices.

Before switching away from M-VAVE's open firmware, `backUpOpenFirmware(progress:)` reads its 16
project slots, the project being edited and its sample bank, and `OpenFirmwareBackup.write(to:)`
saves them as the `.fm1` and `.fm1s` files M-VAVE's workbench restores. Other firmwares have no
known way to read their data, and each firmware stores it in its own format, so a backup is only
for putting back on open firmware.

From V15, `installBootloader(_:events:)` installs
[m-bootloader](https://github.com/jvitkauskas/m-bootloader) from its `fm1-uboot.fwsc` package,
keeping the firmware. m-bootloader replaces M-VAVE's bootloader with one that has a recovery menu
(hold PLAY while switching on) and the chip's USB download mode (hold REC). FM1Kit can't read the
bootloader back over USB-MIDI, so the FM-1's screen confirms it, and installing V15 later puts
M-VAVE's bootloader back.

### FM1Rescue (macOS)

The package's second library, `FM1Rescue`, uses the chip's USB download mode, which works even
when an FM-1's firmware won't start. It's macOS-only: in download mode the FM-1 shows up as a USB
disk, and taking it from macOS's disk driver needs root, which iOS apps can't have. On iOS the
library is empty.

```swift
import FM1Rescue

try await updater.enterDownloadMode()               // V15 or Felucca; or hold REC with m-bootloader
let session = try FlashSession(connection: USBDownloadModeConnection.open())   // needs root
let backup = try session.backUp { print("\(Int($0 * 100))%") }
try backup.write(to: backupsFolder)                  // fm1-YYYYMMDD-HHMMSS.bin and .json

let plan = try FlashPlan.installing(mBootloader, onto: backup)   // or restoring(_:onto:), …
print(plan.notes, plan.warnings, plan.sectors.count)            // show, then ask to confirm
try session.write(plan) { print("\(Int($0 * 100))%") }          // writes and checks each change
session.close()                                      // switch the FM-1 off and on to leave
```

`FlashSession` uploads m-bootloader's flash loader into the chip's RAM and reads the flash; a
backup reads it twice and checks both reads against the chip's own CRC-32. Backups are saved as
M-Flasher saves them, so either tool can restore them. A `FlashPlan` restores a backup, installs
m-bootloader (or M-VAVE's bootloader from a firmware package) or installs a firmware, changing
only the 4 KB sectors that differ; another FM-1's backup never replaces this one's factory
data. Writing checks the flash is still what was read, then checks every change against the
chip's CRC-32. `SimulatedDownloadMode` stands in for the chip in tests and previews.

For apps aimed at everyone, `InstallProgress` folds an install's events into one bar that never
goes backwards, `FM1Advice` turns any error into a headline, whether the FM-1 is still fine and
the one thing to do next, and `summary()` describes the connected FM-1, with its serial number.

Reading a package checks its contents first: the header, the chip it's built for, a checksum
for each part, and that it holds a firmware image and an update loader. A damaged or wrong
file is refused before anything is sent to the FM-1.

### What an install looks like

On the FM-1 tested, an install takes about 20 seconds for V15 and under 40 seconds for Felucca
1.6.1. The FM-1 first checks the package while running its current firmware, then restarts
into its update loader, which shows up as a MIDI port with a new name (such as
`Felucca Update`) and reports itself as `ota-` followed by the firmware's name, for example
`ota-FM-1_015` for V15. After M-VAVE's open firmware is armed, its loader instead reports the
build it was armed with, such as `ota-FM1C_db1642b2b6fa5c2c`. The loader may leave the screen
blank. If the update is cut off, the FM-1 waits in its loader until an update finishes, and
`resume` picks it up.

The documentation articles, [FM1Kit](Sources/FM1Kit/FM1Kit.docc/FM1Kit.md) and
[Installing firmware](Sources/FM1Kit/FM1Kit.docc/InstallingFirmware.md), cover the update's
two halves, checking an install before it starts, open firmware, restoring V15's voices,
recovery, keeping an update running on iOS, and testing with `SimulatedFM1`, which speaks the
protocol in software for the iOS Simulator and tests.

### What's in the package

| Type | What it does |
|---|---|
| `FwscPackage` | Reads a `.fwsc` package: its identity, the image the device reads, and its SHA-256 |
| `OfficialFirmware` | Recognises M-VAVE's official releases (V15 and Open V12) by size and checksum |
| `FM1Identity` | Parses what a device reports, e.g. `FM-1_916`, or `ota-FM-1_015` for the update loader |
| `FM1Updater` | Finds the device, checks and installs, resumes, restores V15's voices, and reports progress as `UpdateEvent`s |
| `InstallCheck`, `InstallOptions` | What an install would do, and confirming a switch of firmware |
| `FM1Capability`, `FM1BuildID` | What M-VAVE's open firmware reports, and the build ID it's armed with |
| `OpenFirmwareBackup`, `OpenFirmwareProject` | A backup of open firmware's projects and samples, and its project files |
| `BootloaderInstaller`, `BootloaderImage` | m-bootloader's installer package, and the bootloader it carries |
| `InstallProgress`, `FM1Advice`, `FM1DeviceSummary` | One progress bar, plain advice for any error, and the connected FM-1 in plain terms |
| `FlashSession`, `FlashBackup` (FM1Rescue, macOS) | Download mode: the flash loader, and whole-flash backups |
| `FlashPlan` (FM1Rescue, macOS) | A checked change to the flash in download mode: restoring a backup, installing a bootloader or a firmware |
| `USBDownloadModeConnection`, `SimulatedDownloadMode` (FM1Rescue, macOS) | Download mode over USB (needs root), and in software |
| `CoreMIDITransport` | CoreMIDI connections to real devices |
| `SimulatedFM1` | A software FM-1 for the Simulator and tests |

FM1Kit sticks to the device. Finding and downloading firmwares is left to your app.

### `fm1probe`

A Mac command-line tool for checking a setup, and for watching an install closely. Only
`install`, `install-bootloader`, `restore-voices` and the `flash-` commands that write in
download mode write to the device, and `backup` changes which project open firmware shows while
it reads; each asks you to type YES first:

```sh
swift run fm1probe ports                 # list MIDI ports and which would be probed
swift run fm1probe identify --repeat 20  # ask the connected FM-1 what it's running, 20 times
swift run fm1probe monitor 30            # print any SysEx the FM-1 sends for 30 s
swift run fm1probe watch 60              # show ports as devices come and go
swift run fm1probe inspect FILE.fwsc     # show a package's identity, size and checksum (or a .boot file's, or a .bin backup's firmware)
swift run fm1probe install FILE.fwsc     # install a firmware (--resume, --simulated, --log FILE, --build-id HEX)
swift run fm1probe restore-voices FM-1.fwsc  # rewrite V15's voice banks with its factory voices
swift run fm1probe backup FOLDER         # save open firmware's projects and sample bank to a new folder
swift run fm1probe install-bootloader fm1-uboot.fwsc  # install m-bootloader from V15
swift run fm1probe download-mode         # ask V15 or Felucca to restart into download mode
sudo .build/debug/fm1probe flash-backup FOLDER  # read the whole flash in download mode (after swift build)
sudo .build/debug/fm1probe flash-restore BACKUP.bin FOLDER     # put a backup back, saving the flash to FOLDER first
sudo .build/debug/fm1probe flash-bootloader fm1-uboot.boot FOLDER  # install m-bootloader (or M-VAVE's, from FM-1.fwsc)
sudo .build/debug/fm1probe flash-install FILE.fwsc FOLDER      # install a firmware (--with-bootloader, --erase-settings)
```

The `flash-` commands take `--simulated BACKUP.bin` to rehearse against a simulated FM-1 holding
that backup.

[HARDWARE_TESTING.md](HARDWARE_TESTING.md) is the plan for checking FM1Kit on a real FM-1,
and records the results so far.

[llms.txt](llms.txt) and [llms-full.txt](llms-full.txt) describe the package for language
models. They're published with FM1Kit's page at <https://fm-1.drewr.dev/fm1kit/>.

## Development

`scripts/check.sh` runs everything CI runs: `swift format` and SwiftLint in strict mode, a build
with warnings as errors, the tests, an iOS build, the documentation with warnings as errors, and
unused-code analysis with SwiftLint and Periphery. The package uses Swift 6 language mode with
the `ExistentialAny`, `InternalImportsByDefault` and `MemberImportVisibility` upcoming features.

## Recovery

If an FM-1 doesn't start after an update, some firmwares can start it in USB recovery mode:
hold **OCT−** while switching it on. Many firmwares don't offer this, including M-VAVE's
official V15 and Felucca 1.6.1, and it can't help if the firmware is too damaged to start.

Whenever the FM-1 is in its update loader, whether from recovery mode or an interrupted
update, `FM1Updater.resume(_:events:)` can install a firmware. Otherwise, the route left is the
chip's USB download mode, from a computer: [M-Flasher](https://github.com/jvitkauskas/m-flasher)
backs up, restores and reinstalls an FM-1's whole flash through it. With
[m-bootloader](https://github.com/jvitkauskas/m-bootloader) installed, holding REC while
switching on starts download mode, and holding PLAY opens a recovery menu; m-bootloader also
opens the menu by itself when the firmware fails its checksum. FM1Kit doesn't use download mode
only to read (FM1Rescue, on a Mac), and iPhones and iPads can't use it at all.

## Credits

The protocol implementation is written from the
[FM-1-RE](https://github.com/AL-255/FM-1-RE) reverse-engineering notes
([update protocol](https://github.com/AL-255/FM-1-RE/blob/main/docs/io/11-ota-protocol.md)),
which are WTFPL-licensed. Arming open firmware, restoring V15's voices and backing up open
firmware follow the protocols as M-VAVE's open-source firmware and updater
([fm1_open](https://github.com/m-vave/fm1_open)) use them, and the package checks follow the
container format of kagaimiq's MIT-licensed jl-misctools. Installing m-bootloader and
download mode follow [m-bootloader](https://github.com/jvitkauskas/m-bootloader)'s
specification and [M-Flasher](https://github.com/jvitkauskas/m-flasher) (both MIT, Julius
Vitkauskas), which follows jl-uboot-tool (MIT, Andrey Grigoryev); FM1Rescue bundles
m-bootloader's flash loader, with its licence. FM1Kit
contains no code from GPL-licensed installers. Thanks to M-VAVE for being so encouraging of the
FM-1's custom firmware community, and for publishing their firmware and tools.

FM1Kit doesn't include M-VAVE's firmware. Get the official firmware from
[M-VAVE's downloads](https://www.m-vave.com/download).

## Licence

MIT. See [LICENSE](LICENSE).
