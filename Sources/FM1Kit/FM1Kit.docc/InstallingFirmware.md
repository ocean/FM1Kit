# Installing firmware

Read a package, find the FM-1, install, and recover when an update is cut off.

## Overview

An install has two halves. First the FM-1 checks the package while still running its current
firmware (staging). If it accepts it, it marks itself for update and restarts into its update
loader, which reports itself as `ota-FM-1_…`. An interrupted staging normally leaves the
device on its current firmware. Then the loader reads the package again while writing it. If
that half is interrupted, the device stays in the loader until an update finishes, and
``FM1Updater/resume(_:events:)`` picks up from there.

V15 is believed to refuse a package with its own identity, so the updater doesn't try: it throws
``FM1UpdateError/alreadyInstalled(_:)`` before sending anything but the handshake. Custom
firmwares accept their own identity (Felucca's update code doesn't compare it), and some keep one
identity across releases, so installing the identity a custom firmware reports is
``InstallKind/sameIdentity``, which needs confirming with ``InstallOptions/confirmsSameIdentity``.

### Read the package

```swift
let package = try FwscPackage(data: Data(contentsOf: fileURL))
print(package.product)   // e.g. "FM-1_916", what the device will report once installed
print(package.sha256)    // compare with the publisher's checksum before installing
```

``OfficialFirmware/matching(_:)`` says whether a package is one of M-VAVE's own releases.

### Check what the install would do

Moving the FM-1 to a different firmware (between V15, M-VAVE's open firmware and custom
firmwares) can erase its projects and samples, so the updater won't do it unless asked.
``FM1Updater/check(_:buildID:)`` says what an install would do without changing the device:

```swift
let updater = FM1Updater(transport: try CoreMIDITransport(clientName: "My App"))
let check = try await updater.check(package)
switch check.kind {
case .update: print("A new build of the open firmware \(check.device) is running")
case .switchingFirmware: print("Switching from \(check.device): back up projects and samples first")
case .reinstall: print("\(check.device) is already installed")
case .sameIdentity: print("\(check.device) is running: reinstall it, or update to another release?")
}
```

FM1Kit can't tell custom firmwares apart, so any install other than one open firmware build over
another counts as ``InstallKind/switchingFirmware``. Warn the person updating, and once they've
backed up, confirm it with ``InstallOptions/confirmsSwitchingFirmware``.

### Install it

```swift
let options = InstallOptions(confirmsSwitchingFirmware: true)
let installed = try await updater.install(package, options: options) { event in
    switch event {
    case .staging(let requests): print("Preparing… \(requests)")
    case .writing(let fraction, _): print("Writing \(Int(fraction * 100))%")
    case .checking(let fraction, _): print("Checking \(Int(fraction * 100))%")
    case .finished(let identity): print("Now running \(identity)")
    default: break
    }
}
```

The updater only sends SysEx to ports whose names look like an FM-1
(``FM1Updater/isProbeable(_:)``), so other MIDI gear connected at the same time is left alone.
It refuses to start while more than one FM-1 answers
(``FM1UpdateError/multipleDevices(count:)``), so it can't update the wrong one.

### M-VAVE's open firmware

M-VAVE's open firmware (identities such as `FM-1_8000012`, see ``FM1Identity/isOpenFirmware``)
must be armed with the incoming package's build ID before it will update. The updater asks it
for its ``FM1Capability`` and arms it, using the build IDs of ``OfficialFirmware/known``, or the
one given in ``InstallOptions/buildID``. After an install of known build, it checks the open
firmware reports that build.

### Restore V15's factory voices

Installing V15 over other firmware can leave voice banks holding the earlier firmware's voices,
some of them silent. M-VAVE's updater rewrites all four banks after installing V15, from the V15
package; ``FM1Updater/restoreFactoryVoices(from:progress:)`` does the same, on an FM-1 running
V15 (``FM1Identity/officialV15``), with the official package (``FwscPackage/hasFactoryVoices``):

```swift
if await updater.identify() == .officialV15, package.hasFactoryVoices {
    try await updater.restoreFactoryVoices(from: package) { fraction in
        print("Restoring voices \(Int(fraction * 100))%")
    }
}
```

It replaces every voice in the four banks, including any the person made, and V15 can't read
them back, so warn first. If it's interrupted, some voices may be wrong or silent until it's run
again.

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
