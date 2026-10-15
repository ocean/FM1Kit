# FM1Kit

A Swift package for installing firmware on the [M-VAVE FM-1](https://www.m-vave.com) over
USB-MIDI, from iOS and macOS.

FM1Kit speaks the FM-1's update protocol. It reads `.fwsc` firmware packages, finds the
device, answers its read requests while it stages and writes the new firmware, and checks
the device reports the new firmware afterwards. It can also finish an update that was cut off,
or one started from USB recovery mode.

> [!WARNING]
> FM1Kit hasn't yet been tested widely on real hardware, and its timings may need tuning.
> FM1Kit isn't affiliated with M-VAVE. Installing custom firmware is at your own risk.

## Requirements

- iOS 17 or macOS 14
- Swift 6
- An FM-1 connected by USB: an iPhone or iPad's USB-C port, a Lightning device through Apple's
  camera adapter, or a Mac

## Installation

Add FM1Kit with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/ocean/FM1Kit.git", from: "0.1.0"),
]
```

## Usage

```swift
import FM1Kit

// Read a firmware package and see what it is.
let package = try FwscPackage(data: Data(contentsOf: fileURL))
print(package.product, package.sha256)

// Install it on the connected FM-1.
let updater = FM1Updater(transport: try CoreMIDITransport(clientName: "My App"))
try await updater.install(package) { event in
    if case .writing(let fraction, _) = event {
        print("Writing \(Int(fraction * 100))%")
    }
}

// Finish an update that was cut off, or one started in USB recovery mode.
if let identity = await updater.identify(), identity.isLoader {
    try await updater.resume(package)
}
```

The [documentation](https://swiftpackageindex.com/ocean/FM1Kit/documentation/fm1kit)
covers the update's two halves, recovery, keeping an update running on iOS, and testing
with `SimulatedFM1`, which speaks the protocol in software for the iOS Simulator and tests.

### What's in the package

| Type | What it does |
|---|---|
| `FwscPackage` | Reads a `.fwsc` package: its identity, the image the device reads, and its SHA-256 |
| `OfficialFirmware` | Recognises M-VAVE's official releases by size and checksum |
| `FM1Identity` | Parses what a device reports, e.g. `FM-1_916`, or `ota-FM-1_009` for the update loader |
| `FM1Updater` | Finds the device, installs, resumes, and reports progress as `UpdateEvent`s |
| `CoreMIDITransport` | CoreMIDI connections to real devices |
| `SimulatedFM1` | A software FM-1 for the Simulator and tests |

FM1Kit sticks to the device. Finding and downloading firmwares is left to your app.

### `fm1probe`

A Mac command-line tool for checking a setup without writing anything:

```sh
swift run fm1probe ports              # list MIDI ports and which would be probed
swift run fm1probe identify           # ask the connected FM-1 what it's running
swift run fm1probe inspect FILE.fwsc  # show a package's identity, size and checksum
```

## Recovery

If an FM-1 doesn't start after an update, hold **OCT−** while switching it on. It starts in
USB recovery mode, and `FM1Updater.resume(_:events:)` can install a firmware.

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
