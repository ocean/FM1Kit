# FM1Kit

[![CI](https://github.com/ocean/FM1Kit/actions/workflows/ci.yml/badge.svg)](https://github.com/ocean/FM1Kit/actions/workflows/ci.yml)

A Swift package for installing firmware on the [M-VAVE FM-1](https://www.m-vave.com) over
USB-MIDI, from iOS and macOS.

FM1Kit speaks the FM-1's update protocol. It reads `.fwsc` firmware packages, finds the
device, answers its read requests while it stages and writes the new firmware, and checks
the device reports the new firmware afterwards. It can also finish an update that was cut off,
or one started from USB recovery mode.

> [!WARNING]
> FM1Kit has been tested on one FM-1 so far, from a Mac: installing M-VAVE's official V15 and
> Felucca 1.6.1, pulling the cable part-way through writing, and resuming. Reports from other
> devices and hosts are very welcome (see [CONTRIBUTING.md](CONTRIBUTING.md)).
> FM1Kit isn't affiliated with M-VAVE. Installing custom firmware is at your own risk.

## Requirements

- iOS 17 or macOS 14
- Swift 6.1 or later (Xcode 16.3 or later)
- An FM-1 connected by USB: an iPhone or iPad's USB-C port, a Lightning device through Apple's
  camera adapter, or a Mac

## Installation

Add FM1Kit with Swift Package Manager. There's no tagged release yet, so use the `main` branch:

```swift
dependencies: [
    .package(url: "https://github.com/ocean/FM1Kit.git", branch: "main"),
]
```

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

Before installing, FM1Kit makes sure exactly one FM-1 answers, and refuses to reinstall the
firmware it's running. It installs a different firmware only when told the person updating has
been warned, as M-VAVE's own updater does. It also speaks M-VAVE's open firmware's update
support (`FM-1_8000012` and builds of it), arming it with the package's build ID first.

Reading a package checks its contents first: the header, the chip it's built for, a checksum
for each part, and that it holds a firmware image and an update loader. A damaged or wrong
file is refused before anything is sent to the FM-1.

### What an install looks like

On the FM-1 tested, an install takes about 20 seconds for V15 and under 40 seconds for Felucca
1.6.1. The FM-1 first checks the package while running its current firmware, then restarts
into its update loader, which shows up as a MIDI port with a new name (such as
`Felucca Update`) and reports itself as `ota-` followed by the firmware's name, for example
`ota-FM-1_015` for V15. The loader may leave the screen blank. If the update is cut off, the
FM-1 waits in its loader until an update finishes, and `resume` picks it up.

The documentation articles, [FM1Kit](Sources/FM1Kit/FM1Kit.docc/FM1Kit.md) and
[Installing firmware](Sources/FM1Kit/FM1Kit.docc/InstallingFirmware.md), cover the update's
two halves, recovery, keeping an update running on iOS, and testing with `SimulatedFM1`, which
speaks the protocol in software for the iOS Simulator and tests.

### What's in the package

| Type | What it does |
|---|---|
| `FwscPackage` | Reads a `.fwsc` package: its identity, the image the device reads, and its SHA-256 |
| `OfficialFirmware` | Recognises M-VAVE's official releases by size and checksum |
| `FM1Identity` | Parses what a device reports, e.g. `FM-1_916`, or `ota-FM-1_015` for the update loader |
| `FM1Updater` | Finds the device, installs, resumes, and reports progress as `UpdateEvent`s |
| `CoreMIDITransport` | CoreMIDI connections to real devices |
| `SimulatedFM1` | A software FM-1 for the Simulator and tests |

FM1Kit sticks to the device. Finding and downloading firmwares is left to your app.

### `fm1probe`

A Mac command-line tool for checking a setup, and for watching an install closely. Only
`install` writes to the device, and only after you type YES to confirm:

```sh
swift run fm1probe ports                 # list MIDI ports and which would be probed
swift run fm1probe identify --repeat 20  # ask the connected FM-1 what it's running, 20 times
swift run fm1probe monitor 30            # print any SysEx the FM-1 sends for 30 s
swift run fm1probe watch 60              # show ports as devices come and go
swift run fm1probe inspect FILE.fwsc     # show a package's identity, size and checksum
swift run fm1probe install FILE.fwsc     # install a firmware (--resume, --simulated, --log FILE, --build-id HEX)
```

[HARDWARE_TESTING.md](HARDWARE_TESTING.md) is the plan for checking FM1Kit on a real FM-1,
and records the results so far.

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
update, `FM1Updater.resume(_:events:)` can install a firmware. Otherwise, the only route left
is the chip's ROM bootloader from a computer, which FM1Kit doesn't cover. Some firmware
projects publish `jl-uboot-tool` rescues for it, but FM-1-RE says that route hasn't been
demonstrated on the FM-1.

## Credits

The protocol implementation is written from the
[FM-1-RE](https://github.com/AL-255/FM-1-RE) reverse-engineering notes
([update protocol](https://github.com/AL-255/FM-1-RE/blob/main/docs/io/11-ota-protocol.md)),
which are WTFPL-licensed. It contains no code from GPL-licensed installers. Thanks to M-VAVE
for being so encouraging of the FM-1's custom firmware community.

FM1Kit doesn't include M-VAVE's firmware. Get the official firmware from
[M-VAVE's downloads](https://www.m-vave.com/download).

## Licence

MIT. See [LICENSE](LICENSE).
