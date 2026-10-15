# ``FM1Kit``

Install firmware on an M-VAVE FM-1 over USB-MIDI, from iOS or macOS.

## Overview

FM1Kit speaks the FM-1's USB-MIDI update protocol: it finds the device, reads `.fwsc` firmware
packages, answers the device's read requests while it stages and writes the new firmware, and
checks the device reports the new firmware once it restarts. It can also finish an update that
was cut off, or one started from USB recovery mode (holding OCT− while switching the FM-1 on).

It works with CoreMIDI on any class-compliant connection: an iPhone or iPad's USB-C port, a
Lightning device through Apple's camera adapter, or a Mac. For the iOS Simulator and tests,
``SimulatedFM1`` stands in for the device.

FM1Kit isn't affiliated with M-VAVE, and installing custom firmware is at your own risk.

## Topics

### Essentials

- <doc:InstallingFirmware>
- ``FM1Updater``
- ``FwscPackage``

### Devices and identities

- ``FM1Identity``
- ``OfficialFirmware``
- ``FoundDevice``

### Progress and errors

- ``UpdateEvent``
- ``FM1UpdateError``
- ``UpdaterTiming``

### Connections

- ``MIDITransport``
- ``MIDIConnection``
- ``MIDIPortDescriptor``
- ``CoreMIDITransport``
- ``SimulatedFM1``
- ``SysexInbox``
- ``MIDITransportError``

### Protocol messages

- ``FM1Message``
- ``FM1ReadRequest``
- ``SevenBit``
- ``UMPSysex7``
