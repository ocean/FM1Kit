# Installing firmware

Read a package, find the FM-1, install, and recover when an update is cut off.

## Overview

An install has two halves. First the FM-1 checks the package while still running its current
firmware (staging). If it accepts it, it marks itself for update and restarts into its update
loader, which reports itself as `ota-FM-1_…`. An interrupted staging normally leaves the
device on its current firmware. Then the loader reads the package again while writing it. If
that half is interrupted, the device stays in the loader until an update finishes, and
``FM1Updater/resume(_:events:)`` picks up from there.

The FM-1 refuses a package it judges to be the firmware it's already running: staging then
stops without restarting into the loader, and the updater reports
``FM1UpdateError/stalled(phase:requests:)`` in the `.staging` phase.

### Read the package

```swift
let package = try FwscPackage(data: Data(contentsOf: fileURL))
print(package.product)   // e.g. "FM-1_916", what the device will report once installed
print(package.sha256)    // compare with the publisher's checksum before installing
```

``OfficialFirmware/matching(_:)`` says whether a package is one of M-VAVE's own releases.

### Install it

```swift
let updater = FM1Updater(transport: try CoreMIDITransport(clientName: "My App"))
let installed = try await updater.install(package) { event in
    switch event {
    case .staging(let requests): print("Checking… \(requests)")
    case .writing(let fraction, _): print("Writing \(Int(fraction * 100))%")
    case .finished(let identity): print("Now running \(identity)")
    default: break
    }
}
```

The updater only sends SysEx to ports whose names look like an FM-1
(``FM1Updater/isProbeable(_:)``), so other MIDI gear connected at the same time is left alone.

### Resume an interrupted update

When ``FM1UpdateError/disconnected(phase:requests:)`` or
``FM1UpdateError/stalled(phase:requests:)`` is thrown in the `.writing` phase, or the device
turns up reporting an identity whose ``FM1Identity/isLoader`` is `true` (for example after
being switched on with OCT− held, on a firmware that supports USB recovery), install the
package again with
``FM1Updater/resume(_:events:)``:

```swift
if let identity = await updater.identify(), identity.isLoader {
    try await updater.resume(package)
}
```

### Keep the update running on iOS

An update takes a minute or two. iOS suspends apps that leave the foreground, so keep the app
open while it runs: set `UIApplication.shared.isIdleTimerDisabled` to stop the screen locking,
and ask the person to stay in the app. If the update is cut off anyway, the device waits in
its loader and ``FM1Updater/resume(_:events:)`` finishes it.

### Test without a device

``SimulatedFM1`` speaks the same protocol in software. Tell it which package to expect, then
use it as the transport:

```swift
let device = SimulatedFM1()
device.prepare(for: package)
let updater = FM1Updater(transport: device)
try await updater.install(package)
```

Its ``SimulatedFM1/Options`` can start it in recovery mode, or pull the cable part-way through
writing, to exercise the resume path.
