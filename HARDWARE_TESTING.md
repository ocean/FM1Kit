# Testing on a real FM-1

FM1Kit's tests run against a simulated FM-1. This is the plan for checking it against real
hardware, starting with steps that can't change the device.

Each stage only starts once the one before it has passed. Please record every command's output:
it's the evidence for tuning `UpdaterTiming` and for any fixes.

## Before starting

- A Mac with the FM-1 connected by USB.
- Quit anything else that talks MIDI: DAWs, the M-VAVE editor, and browser tabs with a web
  installer or editor open (Chrome's Web MIDI can hold the port).
- In a terminal: `cd ~/code/FM1Kit`.
- Note which firmware the FM-1 is running, and keep its `.fwsc` file to hand.

## Stage A: read-only, firmware running

Nothing here changes the device. The only message `fm1probe` ever sends is the handshake
query, the same one every installer sends to ask the FM-1 what it is.

| Step | Command | What to look for |
|---|---|---|
| A1 | `swift run fm1probe ports` | The FM-1's port, marked `probe`. If it's marked `skip`, FM1Kit's port-name filter misses the real device: note the name. |
| A2 | `swift run fm1probe identify` | The raw reply and the identity, e.g. `FM-1_91036`. If A1 said `skip`, add `--port "NAME"`. |
| A3 | `swift run fm1probe identify --repeat 50` | 50 of 50 answered, with steady reply times. |
| A4 | `swift run fm1probe inspect FILE.fwsc` | The installed firmware's package reports the same identity as A2. |
| A5 | `swift run fm1probe monitor 30`, while playing and turning knobs | Any SysEx the FM-1 sends unprompted (notes and controllers aren't shown). Ideally none. |
| A6 | `swift run fm1probe watch 90`, then unplug and replug, and switch off and on | Each change shows up. Note how long the port takes to come back after switching on. |

What these prove: the port pairing and name filter work on real hardware; the CoreMIDI
event-list path sends and receives SysEx; the reply parser, 7-bit unpacking and checksum agree
with the device; and how quickly the device re-enumerates, which sets the reconnect timings.

## Stage B: read-only, USB recovery mode

This stage also sends only the handshake, but it starts the FM-1 in its update loader. Normally
the FM-1 starts its firmware again the next time it's switched on as usual, but this hasn't
been confirmed with FM1Kit yet. Before starting, have a known-good way to install firmware ready
(M-VAVE's updater, or a web installer) and the official `FM-1.fwsc` downloaded. Skip this stage
if that isn't possible.

Only some firmwares start the loader when OCT− is held at power-on: FM-1-RE names the SLOOP
family and zp12. The firmware checks the key as it starts, so it's not a feature of the chip's
ROM, and it can't rescue a firmware too damaged to start. Felucca 1.6.1 ignores it (see
[Results](#results)), so this stage needs a firmware that supports it. The loader is still
tested in stage D, because every install restarts into it.

| Step | Command | What to look for |
|---|---|---|
| B1 | `swift run fm1probe watch 60`, then switch the FM-1 off and on while holding OCT− | The loader's port name. FM-1-RE reports the loader re-enumerating as USB ID `4d4a:4155`. |
| B2 | `swift run fm1probe ports` | The loader's port is marked `probe`. If not, note the name: `resume` would miss it. |
| B3 | `swift run fm1probe identify` | An identity starting `ota-`, e.g. `ota-FM-1_009`, reported as the update loader. |
| B4 | Switch off, then on as usual; `swift run fm1probe identify` | The firmware's identity again, as in A2. |

## Stage C (optional): read-only on an iPhone or iPad

Install FM-SWITCH on the phone, connect the FM-1 to its USB-C port (or a Lightning device
through Apple's camera adapter), and open the DEVICE tab. It sends only the handshake. This
checks FM1Kit's CoreMIDI transport on iOS, which can differ from macOS.

## Stage D: the first install (a later session)

Only once stage A has passed, and stage B too if the running firmware supports recovery mode.
This needs an `fm1probe install` command, which hasn't
been written yet, so that a first install can be watched closely from a Mac.

- Install a firmware other than the one running: the FM-1 refuses to reinstall the firmware it's
  running. The official V15 firmware is the most recoverable choice.
- Keep a known-good installer ready (M-VAVE's updater, or a web installer), with the official
  `FM-1.fwsc`.
- Record the total time, how many requests staging and writing take, and any stalls.
- Then, if it went well: start another install and unplug the cable part-way through writing,
  reconnect, and check that `resume` finishes it.

## What to report

For each stage: the commands' output, the FM-1's firmware before and after, the host (Mac
model and macOS version, or iPhone model and iOS version) and the cable or adapter used.

## Results

### 2026-10-16: Mac15,6, macOS 26.6.2, FM-1 running Felucca 1.6.1 (`FM-1_916`)

- **Stage A: passed.**
  - The port is named `Felucca` and is marked `probe`.
  - `identify` answered 50 of 50, averaging 7 to 12 ms (2 to 81 ms).
  - `inspect` on the Felucca 1.6.1 package reports `FM-1_916`, as the device does.
  - No unprompted SysEx arrived during 30 s of playing and turning knobs.
  - `watch` saw every unplug, replug and power cycle. The port returns under 3 s after power-on.
- **Stage B: not possible on this firmware.** Holding OCT− at power-on (for 6 s the second time)
  made no difference: Felucca started normally and no loader port appeared.
