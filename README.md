# FM1Kit

[![CI](https://github.com/ocean/FM1Kit/actions/workflows/ci.yml/badge.svg)](https://github.com/ocean/FM1Kit/actions/workflows/ci.yml)

A Swift package for installing firmware on the [M-VAVE FM-1](https://www.m-vave.com) over
USB-MIDI, from iOS and macOS.

FM1Kit reads `.fwsc` firmware packages and speaks the FM-1's update protocol: it finds the FM-1,
answers its read requests while it stages and writes the new firmware, and checks the FM-1
reports the new firmware afterwards. It also finishes updates that were cut off, says before an
install how to switch away from that firmware later, and on a Mac works with the whole flash
when the firmware won't start.

> [!NOTE]
> FM-SWITCH, an iPhone and iPad app built on FM1Kit, has installed and switched firmware for
> several hundred TestFlight testers since October 2026. The Mac-only flash tools, in download
> mode and through the FM-1 Transporter, have been tested on one FM-1 so far.
> [HARDWARE_TESTING.md](HARDWARE_TESTING.md) records what was tested, and reports from other
> FM-1s are welcome (see [CONTRIBUTING.md](CONTRIBUTING.md)). FM1Kit isn't affiliated with
> M-VAVE, and installing custom firmware is at your own risk.

## Requirements

- iOS 17 or macOS 14
- Swift 6.1 or later (Xcode 16.3 or later)
- An FM-1 connected by USB: to an iPhone or iPad's USB-C port, to a Lightning one through Apple's
  camera adapter, or to a Mac

## Installation

Add FM1Kit with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/ocean/FM1Kit.git", .upToNextMinor(from: "0.7.1")),
]
```

Until 1.0, minor versions may change the API, so this takes 0.7.x fixes but not 0.8.0.
[CHANGELOG.md](CHANGELOG.md) lists the changes.

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
    case .checking(let fraction, _): print("Second pass \(Int(fraction * 100))%")
    case .finished(let identity): print("Now running \(identity)")
    default: break
    }
}

// Finish an update that was cut off, or one started in USB recovery mode.
if let identity = await updater.identify(), identity.isLoader {
    try await updater.resume(package)
}
```

Reading a package checks it first: its header, the chip it's built for, each part's checksum,
and that it holds a firmware image and an update loader. A damaged or wrong file is refused
before anything is sent to the FM-1.

Before installing, FM1Kit makes sure exactly one FM-1 answers. It installs a different firmware,
or reinstalls the one already running, only when told the person updating has confirmed it, as
M-VAVE's own updater does. It won't install V15 over a firmware reporting V15's identity unless
told that firmware is something else, such as TransitFM1. For M-VAVE's open firmware
(`FM-1_8000012` and its builds), FM1Kit arms its update support with the package's build ID
first.

Each firmware brings its own update loader, and loaders write differently. Writing progress
counts the firmware's application area, which every loader seen so far writes, in whatever order
it reads (V15's reads backwards). Some loaders, Felucca's among them, then read it all a second
time, which FM1Kit reports as `.checking`, so progress displays need room for an optional second
step.

### Switching between firmwares

Many firmwares built on Felucca's platform, from before its October 2026 fix, refuse V15, V16 or
M-VAVE's open firmware, depending on the FM-1's bootloader. From an iPhone, the way past them is
two installs: MIDIMON 0.5 first, then the firmware wanted. `PackageCheck` reports this and other
problems in a package before it's installed, and `LeavingGuide` works out how to switch away
from a firmware before it goes on, with steps in plain words.

Each firmware keeps its settings in the same part of the flash, in its own format, and no install
over USB-MIDI clears it. V15 installed after V16 plays one note at a time until it's cleared,
which takes a Mac in download mode. After installing V15, `restoreFactoryVoices(from:progress:)`
rewrites its four voice banks with the 128 factory voices from the V15 package, as M-VAVE's
updater does.

Some firmwares keep samples or other data in a resource region of the flash. A package that
carries them gets them written by its update loader, and in download mode by FM1Kit too. For
resources published beside the package as `NAME-res.bin`, as LOOM-8's are from 0.12,
`writeResources(_:progress:)` sends them to the firmware once it's running.

Before switching away from M-VAVE's open firmware, `backUpOpenFirmware(progress:)` reads its 16
project slots, the project being edited and its sample bank, and `OpenFirmwareBackup.write(to:)`
saves them as the `.fm1` and `.fm1s` files M-VAVE's workbench restores. No other firmware has a
known way to read its data back.

From V15, `installBootloader(_:fromAnyFirmware:events:)` installs
[m-bootloader](https://github.com/jvitkauskas/m-bootloader) from its `fm1-uboot.fwsc` package
and keeps the firmware. m-bootloader adds a recovery menu (hold PLAY while switching on) and the
chip's USB download mode (hold REC). FM1Kit can't read the bootloader back over USB-MIDI, so the
FM-1's screen confirms it. Installing V15 later puts M-VAVE's bootloader back.

For apps aimed at everyone, `InstallProgress` folds an install's events into one bar that never
goes backwards, `FM1Advice` turns any error into a headline, whether the FM-1 is still fine and
the one thing to do next, and `summary()` describes the connected FM-1 with its serial number.

### What an install looks like

An install takes about 20 seconds for V15 and under 40 seconds for Felucca 1.6.1. The FM-1
checks the package while running its current firmware, then restarts into its update loader,
which appears as a MIDI port with a new name (such as `Felucca Update`) and reports `ota-`
followed by the firmware's name, such as `ota-FM-1_015` for V15. Once armed, M-VAVE's open
firmware's loader reports the build instead, such as `ota-FM1C_db1642b2b6fa5c2c`. The screen may
stay blank. If the update is cut off, the FM-1 waits in its loader until an update finishes, and
`resume` picks it up.

The documentation articles, [FM1Kit](Sources/FM1Kit/FM1Kit.docc/FM1Kit.md) and
[Installing firmware](Sources/FM1Kit/FM1Kit.docc/InstallingFirmware.md), cover checking an
install before it starts, switching, open firmware, V15's voices, recovery, keeping an update
running on iOS, and testing with `SimulatedFM1`, which speaks the protocol in software for the
iOS Simulator and tests.

### FM1Rescue (macOS)

The package's second library, `FM1Rescue`, works with the whole flash through the chip's USB
download mode, which works even when the firmware won't start. In download mode the FM-1 shows
up as a USB disk, and taking it from macOS's disk driver needs root, so FM1Rescue is macOS-only.
On iOS the library is empty.

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

`FlashSession` uploads m-bootloader's flash loader into the chip's RAM. A backup reads the flash
twice and checks both reads against the chip's CRC-32, and saves it as M-Flasher does, so either
tool can restore it. A `FlashPlan` restores a backup, installs a bootloader or installs a
firmware, and changes only the 4 KB sectors that differ. Another FM-1's backup never replaces
this FM-1's factory data. Writing checks the flash is still what was read, then checks every
change against the chip's CRC-32. `SimulatedDownloadMode` stands in for the chip in tests.

An FM-1 that never reaches download mode, because the firmware that would restart into it
doesn't start, needs the chip's boot ROM. The [FM-1 Transporter](https://github.com/kurogedelic/FM-1-transporter)
reaches it with an RP2040 wired to the FM-1's USB data lines, and `Transporter` works with it
from FM1Rescue: it waits for the FM-1 to be switched on, starts a flash loader, backs up, and
writes a plan between 0x4000 and 0x92FFF, reading it all back afterwards. Since the Transporter
can't write the saved-data area above that, a plan that changes firmware says to install again
in download mode once the FM-1 starts, erasing saved data. `Transporter` starts m-bootloader's
flash loader, which needs Transporter firmware whose loader request takes an address and size.
The Transporter's v0.1.0 release takes only jl-uboot-tool's `wl82loader.bin`, which FM1Kit
doesn't include; pass that instead ([RECOVERY.md](RECOVERY.md) says where to get it).

### What's in the package

| Type | What it does |
|---|---|
| `FwscPackage` | Reads a `.fwsc` package: its identity, the image the FM-1 reads, and its SHA-256 |
| `OfficialFirmware` | Recognises M-VAVE's releases (V15, V16 and Open V12) and says which may be included in an app (only V15) |
| `FM1Identity` | Parses what an FM-1 reports, such as `FM-1_916`, or `ota-FM-1_015` for the update loader |
| `FM1Updater` | Finds the FM-1, checks and installs, resumes, restores V15's voices, and reports progress as `UpdateEvent`s |
| `InstallCheck`, `InstallOptions` | What an install would do, and confirming a switch of firmware |
| `PackageCheck` | Problems in a package before it's installed, for firmware developers and apps |
| `LeavingGuide` | How to switch away from a firmware later, worked out before it's installed |
| `FM1Capability`, `FM1BuildID` | What M-VAVE's open firmware reports, and the build ID it's armed with |
| `OpenFirmwareBackup`, `OpenFirmwareProject` | A backup of open firmware's projects and samples, and its project files |
| `BootloaderInstaller`, `BootloaderImage` | m-bootloader's installer package, and the bootloader it carries |
| `InstallProgress`, `FM1Advice`, `FM1DeviceSummary` | One progress bar, plain advice for any error, and the connected FM-1 in plain terms |
| `FlashSession`, `FlashBackup` (FM1Rescue, macOS) | Download mode: the flash loader, and whole-flash backups |
| `FlashPlan` (FM1Rescue, macOS) | A checked change to the flash: restoring a backup, or installing a bootloader or a firmware |
| `USBDownloadModeConnection`, `SimulatedDownloadMode` (FM1Rescue, macOS) | Download mode over USB (needs root), and in software |
| `Transporter`, `SerialTransporterLink`, `SimulatedTransporter` (FM1Rescue, macOS) | The FM-1 Transporter, over its serial port and in software |
| `CoreMIDITransport` | CoreMIDI connections to real FM-1s |
| `SimulatedFM1` | A software FM-1 for the Simulator and tests |
| `CoreMIDIVirtualDevice` | Publishes a `SimulatedFM1` on virtual CoreMIDI ports, for testing other updaters |

FM1Kit sticks to the FM-1. Finding and downloading firmwares is left to your app.

### `fm1probe`

A Mac command-line tool for checking a setup, inspecting packages and watching an install
closely. Every command that writes to the FM-1 asks you to type YES first, and so does `backup`,
which changes the project open firmware shows while it reads.

```sh
swift run fm1probe ports                 # list MIDI ports and which would be probed
swift run fm1probe identify --repeat 20  # ask the connected FM-1 what it's running, 20 times
swift run fm1probe monitor 30            # name each SysEx message the FM-1 sends for 30 s (--log FILE, --hex)
swift run fm1probe replay LOG.csv        # print a --log file, naming each message (--all for every read)
swift run fm1probe watch 60              # show ports as FM-1s come and go
swift run fm1probe inspect FILE.fwsc     # a package's identity, size and checksum (or a .boot file's, or a .bin backup's firmware)
swift run fm1probe check FILE.fwsc       # pre-release report for firmware developers (--strict for CI, --json)
swift run fm1probe diff FIRST SECOND     # compare two packages or two .bin backups, part by part (--json)
swift run fm1probe simulate FILE.fwsc    # a simulated V15 on a virtual MIDI port, for testing updaters
swift run fm1probe install FILE.fwsc     # install a firmware (--resume, --simulated, --log FILE, --build-id HEX)
swift run fm1probe restore-voices FM-1.fwsc  # rewrite V15's voice banks with its factory voices
swift run fm1probe write-resources NAME-res.bin  # write a firmware's published resources to it
swift run fm1probe backup FOLDER         # save open firmware's projects and sample bank to a new folder
swift run fm1probe install-bootloader fm1-uboot.fwsc  # install m-bootloader from V15
swift run fm1probe download-mode         # ask V15 or Felucca to restart into download mode
sudo .build/debug/fm1probe flash-backup FOLDER  # read the whole flash in download mode (after swift build)
sudo .build/debug/fm1probe flash-restore BACKUP.bin FOLDER     # put a backup back, saving the flash to FOLDER first
sudo .build/debug/fm1probe flash-bootloader fm1-uboot.boot FOLDER  # install m-bootloader (or M-VAVE's, from FM-1.fwsc)
sudo .build/debug/fm1probe flash-install FILE.fwsc FOLDER      # install a firmware (--with-bootloader, --erase-saved-data)
swift run fm1probe transporter check     # start the flash loader through the FM-1 Transporter and check the chip
swift run fm1probe transporter backup FOLDER  # back up through the Transporter
swift run fm1probe transporter install FILE.fwsc FOLDER  # install through it (restore BACKUP.bin FOLDER to put a backup back)
swift run fm1probe flash-image FILE.fwsc BACKUP.bin IMAGE.bin  # a flash image for the Transporter's web app
```

`fm1probe simulate FILE.fwsc` tests an updater of your own, or M-UPGRADE, without risking an
FM-1. A simulated FM-1 appears as the MIDI port "FM-1 Midi (simulated)", checks every byte the
updater sends against the package, restarts into its update loader as a real one does, and
prints each message and what it does. `--identity FM-1_8000012` makes it report another
firmware, `--loader` starts it in its update loader, `--flash-chip B36014` reports the newer
flash chip, and `--seconds N` stops it after N seconds.

`devices`, `identify`, `inspect`, `check` and `diff` take `--json` for scripts and CI: one JSON
object on standard output, whose `format` names its layout and version (such as
`fm1probe-check-1`). Fields that aren't known are left out.

The download-mode `flash-` commands take `--wait SECONDS` for an FM-1 whose firmware crashes at
start-up and passes through download mode for a few seconds at a time
(`USBDownloadModeConnection.open(waitingUpTo:)`). They and the `transporter` commands take
`--simulated BACKUP.bin` to rehearse against a simulated FM-1 holding that backup. The
`transporter` commands also take `--loader wl82loader.bin`, `--port PATH` and `--wait SECONDS`.

[llms.txt](llms.txt) and [llms-full.txt](llms-full.txt) describe the package for language
models. They're published with FM1Kit's page at <https://fm-1.drewr.dev/fm1kit/>.

## Development

`scripts/check.sh` runs everything CI runs: `swift format` and SwiftLint in strict mode, a build
with warnings as errors, the tests, an iOS build, the documentation with warnings as errors, and
unused-code analysis with SwiftLint and Periphery. The package uses Swift 6 language mode with
the `ExistentialAny`, `InternalImportsByDefault` and `MemberImportVisibility` upcoming features.

## Recovery

Some firmwares start in USB recovery mode when **OCT−** is held while switching on. Many don't,
including V15 and Felucca 1.6.1, and it can't help a firmware too damaged to start. Whenever the
FM-1 is in its update loader, from recovery mode or an interrupted update,
`FM1Updater.resume(_:events:)` can install a firmware.

Otherwise the way back is the chip's USB download mode, from a computer. With m-bootloader
installed, holding REC while switching on starts it, and holding PLAY opens the recovery menu,
which also opens by itself when the firmware fails its checksum. Without m-bootloader, V15 and
firmwares on Felucca's platform restart into download mode when asked
(`FM1Updater.enterDownloadMode()`). FM1Rescue and [M-Flasher](https://github.com/jvitkauskas/m-flasher)
both back up, restore and write the flash in download mode. iPhones and iPads can't use it.

An FM-1 that shows nothing on USB, not even download mode, needs the chip's boot ROM:
[RECOVERY.md](RECOVERY.md) walks through reaching it with the FM-1 Transporter.

## Credits

The protocol implementation is written from the
[FM-1-RE](https://github.com/AL-255/FM-1-RE) reverse-engineering notes
([update protocol](https://github.com/AL-255/FM-1-RE/blob/main/docs/io/11-ota-protocol.md)),
which are WTFPL-licensed. Arming open firmware, restoring V15's voices and backing up open
firmware follow the protocols as M-VAVE's open-source firmware and updater
([fm1_open](https://github.com/m-vave/fm1_open)) use them, and the package checks follow the
container format of kagaimiq's MIT-licensed jl-misctools. Installing m-bootloader and download
mode follow [m-bootloader](https://github.com/jvitkauskas/m-bootloader)'s specification and
[M-Flasher](https://github.com/jvitkauskas/m-flasher) (both MIT, Julius Vitkauskas), which
follows jl-uboot-tool (MIT, Andrey Grigoryev). FM1Rescue builds in m-bootloader's flash loader,
and `fm1probe licences` prints its licence. The Transporter support follows the
[FM-1 Transporter](https://github.com/kurogedelic/FM-1-transporter)'s serial protocol. Catching
an FM-1 that passes through download mode, and writing from the top of the flash down, are ideas
from Charles Vestal's [fm1_rescue](https://github.com/hugelton/felucca-bsp/blob/main/tools/fm1_rescue.py).
FM1Kit contains no code from GPL-licensed installers. Thanks to M-VAVE for being so encouraging
of the FM-1's custom firmware community, and for publishing their firmware and tools.

FM1Kit doesn't include M-VAVE's firmware. Get the official firmware from
[M-VAVE's downloads](https://www.m-vave.com/download).

## Licence

MIT. See [LICENSE](LICENSE).
