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
ROM, and it can't rescue a firmware too damaged to start. Neither Felucca 1.6.1 nor
official V15 offers it (see [Results](#results)), so this stage needs a firmware that does. The loader is still
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

## Stage D: the first install

Only once stage A has passed, and stage B too if the running firmware supports recovery mode.
`fm1probe install` checks the package and the device first, then asks you to type YES
before anything is written. It prints each step with timestamps and ends with a
summary of the time, the requests and the longest gap between requests in each step. With
`--log FILE` it also writes every message to and from the device to a CSV file, including each
read request's address and length. Run it in
a terminal rather than through an agent, so the progress shows as it happens.

- Install a firmware other than the one running: the FM-1 refuses to reinstall the firmware it's
  running. The official V15 firmware is the most recoverable choice.
- Keep a known-good installer ready (M-VAVE's updater, or a web installer), with the official
  `FM-1.fwsc`.

| Step | Command | What to look for |
|---|---|---|
| D1 | `swift run fm1probe install FM-1.fwsc --simulated` | A rehearsal against the simulated FM-1, which writes nothing. It should finish with `Installed`. |
| D2 | `swift run fm1probe install FM-1.fwsc`, then type `YES` | Staging, the loader, writing and the restart, ending `Installed: the FM-1 is running FM-1_015`. Keep the summary. |
| D3 | `swift run fm1probe identify`, then switch the FM-1 off and on | It reports `FM-1_015` and starts normally. If wanted, try stage B again: V15 may support recovery mode. |
| D4 | `swift run fm1probe install OTHER.fwsc --log d4.csv`, then unplug the cable part-way through writing | It stops while writing. Reconnect, and `fm1probe identify` reports the `ota-` loader. |
| D5 | `swift run fm1probe install OTHER.fwsc --resume --log d5.csv` | The loader writes the package again from the start, ending `Installed`. |

## Stage E: M-VAVE's open firmware

FM1Kit arms open firmware before an update, as M-VAVE's own updater does, but this hasn't been
tried on hardware. M-VAVE marks Open V12 as not yet validated on hardware either, so only do
this stage with V15 ready to install. The Open V12 package is embedded in M-VAVE's
`FM1-Open-V12-Workbench.html` release; `fm1probe inspect` should report it as `FM1 Open V12`.

| Step | Command | What to look for |
|---|---|---|
| E1 | `swift run fm1probe install FM-1_8000012.fwsc --log e1.csv`, from V15 | "switching to a different firmware", then a normal install: V15's firmware needs no arming, and the stock loader reports `ota-FM-1_015`. Ends `Installed: … FM-1_8000012`. |
| E2 | `swift run fm1probe identify` | `FM-1_8000012`. |
| E3 | `swift run fm1probe install FM-1.fwsc --log e3.csv` | An `Open:` line with the running build (`426b7fa5…`) and `ready`, then arming, staging and writing as usual, ending `Installed: … FM-1_015`. The log shows the capability query (`0x31`) and arming request (`0x32`) before the upgrade command. |

| E4 | Play through V15's voices, switching between several in each bank | Whether they're V15's factory sounds. If any are wrong, silent or garbled, note which banks. |

E4 decides whether FM1Kit needs a factory voice restore. M-VAVE's updater rewrites the four voice
banks after installing V15, but on this FM-1 an install of V15 after several custom firmwares
(Ghoulbox, SLOOP, Melodee, Felucca) brought the factory voices back without one, although the
logs show no voice data from the package reaching the device. The likeliest explanation is that
V15 resets banks it can't read to built-in defaults. Open firmware may leave banks that V15 can
read, in which case its voices would stay until restored, and the restore would have a real job.

## Stage F: restoring V15's factory voices

M-VAVE's updater rewrites V15's voice banks after installing V15, and FM1Kit now can too. It
replaces every voice in the four banks and can't read them back, so the only check is listening.
Run it on V15 (`FM-1_015`) with the official `FM-1.fwsc`.

| Step | Command | What to look for |
|---|---|---|
| F1 | `swift run fm1probe restore-voices FM-1.fwsc --simulated` | A rehearsal against a simulated V15: 0% to 100%, then `Restored`. |
| F2 | `swift run fm1probe restore-voices FM-1.fwsc --log f2.csv`, then type `YES` | 0% to 100% in a few seconds, then `Restored V15's factory voices`. The log shows 4 erases (`0x21`) and 32 writes (`0x22`), each acknowledged. |
| F3 | Play voices 000–127, switching between several in each bank | All factory sounds, including 096–127, which held earlier firmwares' voices in stage E. |
| F4 | `swift run fm1probe identify`, then switch the FM-1 off and on and play again | Still `FM-1_015`, and the voices survive a restart. |

If F2 stops part-way, some voices may be silent: run it again.

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
- **Stage D1: passed.** The simulated rehearsal installed `FM-1_015` in 34.6 s.
- **Stage D2: passed.** `fm1probe install` took the FM-1 from Felucca 1.6.1 (`FM-1_916`) to
  official V15 (`FM-1_015`) in 34.7 s:
  - Staging: 4.2 s, 75 requests, with at most 121 ms between requests.
  - The loader answered as `ota-FM-1_015` (the incoming version, not `ota-FM-1_009` as in
    FM-1-RE's recording) on the first scan after the 3 s pause.
  - Writing: 24.4 s, 1167 requests, with at most 350 ms between requests. 1167 reads of at most
    512 bytes can't cover the 699,936-byte image, so the loader doesn't read all of it.
  - The firmware answered on the first scan after the 3 s restart pause.
  - Writing progress jumped from 0% to 80% within 14 requests and then stayed there until the
    end, so the loader doesn't read the image in order. Progress based on the furthest offset
    read is wrong for the real device.
- **Stage D3: passed.** After the install, `identify` reported `FM-1_015` (port name `FM-1`),
  answering in 1 ms. Holding OCT− while switching on did nothing on V15 either: the official
  firmware doesn't offer USB recovery mode.
- **Stage D4: passed.** Installing Felucca 1.6.1 over V15, the cable was pulled after 116 write
  requests. `install` stopped with "The update loader disconnected", and after replugging the
  loader answered as `ota-FM-1_900` on a port named `Felucca Update`, with a blank screen and
  the red light on. Staging took only 22 requests this time, against 75 for V15.
- **Stage D5: passed.** `install --resume` finished the update in 57.1 s, and the FM-1 reported
  `FM-1_916`. The log shows the loader making two passes over the image after a few header
  reads (`0x0`–`0x400`, then 32 bytes at `0x4400`):
  - first `0x400`–`0x93400` (1176 reads, 22.7 s);
  - then `0x4400`–`0x93400` again (1144 reads, 29.2 s), probably checking what it wrote.
  Progress reached 90% at the end of the first pass, then showed nothing during the second.
- **Logged installs (2026-10-16): V15 over Felucca, then Felucca over V15.** Each package
  seems to bring its own loader: it reported `ota-FM-1_015` for V15 and `ota-FM-1_900` for
  Felucca every time, and the two read differently. Both write the region `0x4400`–`0x93400`
  whatever the package's size; the rest of the image is read only while staging.
  - V15's loader: one pass, backwards from `0x93400` to `0x4400` (1144 reads, 21 s), then a
    few reads of 10 to 16 bytes from the header. Writing reads about 84% of the image.
  - Felucca's loader: forwards from `0x400` to `0x93400` (1176 reads), then forwards again
    from `0x4400` (1144 reads), 55 s in all. It did the same after the D5 resume.
  - So FM1Kit now measures writing as the share of the image read in any order, and reports
    the second pass as a separate checking step. Replaying the three logs through the new
    rules gives steady progress for both loaders, with checking only for Felucca's.
  - Reading the packages' containers (2026-10-17) explains the region: both packages' firmware
    image (`flash.bin`) runs from `0x400` to `0x93400`, and `0x4400` onwards is its application
    area, after a 16 KB boot area. V15's loader writes only the application area; Felucca's
    rewrites the boot area first. Progress now counts the application area, so replaying the
    logs takes both loaders' writing (and Felucca's checking) steadily to 100%.

### 2026-10-17: the same Mac and FM-1, with no pauses and the package checks

Two logged installs, V15 over Felucca 1.6.1 and then Felucca 1.6.1 over V15, with FM1Kit's
pauses removed (no delay before each reply, none after the upgrade commands), the container
checks, careful finish handling, and progress counted over the application area. Both
finished, and progress looked right throughout. Times run from typing YES to the new firmware
answering:

| | V15 over Felucca | Felucca over V15 |
|---|---|---|
| Staging | 1.3 s, 75 requests (was 4.2 s) | 0.3 s, 22 requests |
| Loader answered | `ota-FM-1_015` after 5.5 s | `ota-FM-1_900` after 5.5 s |
| Writing | 9.6 s, 1167 requests (was 24.4 s) | 27.7 s, 2323 requests over both passes |
| Longest gap between requests | 338 ms | 72 ms |
| Whole install | 20.3 s (was 34.7 s) | 37.2 s (was about 55 s) |

- Each log shows its loader reading every byte of the application area (`0x4400`–`0x93400`).
- Each half ended with a single finish request; no repeats arrived during the settle.
- The firmware answered with the new identity (`FM-1_015`, then `FM-1_916`) on the first
  scan after the restart.

### 2026-10-17: stage E, M-VAVE's open firmware

The same Mac and FM-1, starting from our own custom firmware Estampie (`FM-1_37801`).

- **Estampie → V15:** 20.8 s, as fast as the morning's installs.
- **E1: V15 → Open V12 passed** in 20.8 s. Staging took 47 requests; the stock loader answered
  as `ota-FM-1_015` and wrote Open V12's smaller application area in 900 requests.
- **E2 passed:** the FM-1 reported `FM-1_8000012` on a port named `FM1 Community`, and played,
  with sounds and sequencer tracks already set up.
- **E3: Open → V15 failed, then resumed.**
  - Open answered the capability query (build `426b7fa5…`, ready) and accepted arming.
  - Staging took 47 requests, and the loader appeared about 6 s later on `USB Composite Device`.
  - It reported `ota-FM1C_db1642b2b6fa5c2c`: `ota-FM1C_` and the first 16 hex digits of the build
    it was armed with (V15's SHA-256). FM1Kit only recognised loaders reporting digits after the
    underscore, so it gave up after 30 s with "The update loader didn't appear". The screen was
    blank and the FM-1 waited in the loader.
  - FM1Kit now reads that identity as an FM-1 update loader, and on an install checks the build
    it names. `install --resume` then wrote V15 in 14.5 s (1192 requests, rewriting the boot area
    backwards before the application area) and the FM-1 reported `FM-1_015`.
  - A full Open → V15 install in one go, with the fix, hasn't been tried yet.
- **E4: bank 4 wasn't restored.** On V15, voices 000–095 were factory sounds, but 096–127 (the
  fourth bank of 32) were odd: some from an early Baudgirl voice set, and at least 12 silent or
  making only a ringing noise. So V15 doesn't reset every bank an earlier firmware left behind,
  and FM1Kit needs a factory voice restore, as M-VAVE's updater does after installing V15.

### 2026-10-17: stage F, restoring V15's factory voices

The same Mac and FM-1, on V15 with the fourth voice bank still holding earlier firmwares' voices
(stage E4).

- **F1 and F2 passed.** `fm1probe restore-voices` restored the voices in 0.7 s: 4 erases and 32
  writes of 512 bytes, each acknowledged with 0, and the FM-1 reported `FM-1_015` before and
  after. Writes were acknowledged within 4 ms; the slowest acknowledgements (139 and 386 ms) were
  probably flash erases.
- **F3 passed.** All the voices sounded right afterwards, including 096–127.

