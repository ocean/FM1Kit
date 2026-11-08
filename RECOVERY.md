# Recovering an FM-1 that shows nothing on USB

This guide is for an FM-1 that no longer appears on USB at all. It shows no MIDI port and no
download mode, and `sudo .build/debug/fm1probe flash-backup FOLDER --wait 300` never catches it
across several power cycles. That can happen when an update is cut off and the FM-1 is then
switched off: the firmware that would answer is half written, so it can't start, and the
FM-1's own key combinations and download mode depend on that firmware.

Before following it, try the routes in the README's [Recovery](README.md#recovery) section. They
need no extra hardware.

> **Not yet tried end to end on a real FM-1.** Each piece has been checked on its own, as
> described below: the downloaded files, the source they're built from, the web app and the
> image `fm1probe flash-image` makes. The whole recovery hasn't been run on hardware yet. Go
> slowly, and stop at any step that doesn't show what's described.

## How it works

The FM-1's JieLi chip has a boot ROM that can't be changed. A particular signal on the USB data
lines at power-on starts it, whatever is in the flash. The
[FM-1 Transporter](https://github.com/kurogedelic/FM-1-transporter) (kurogedelic, MIT) is
firmware for a Raspberry Pi RP2040 board:

- It sends that signal, then acts as the USB host for the FM-1 on two of the board's pins.
- It passes requests from the computer through, over a USB serial port.

To read and write the flash, the boot ROM needs a small flash loader, `wl82loader.bin`, from
kagaimiq's [jl-uboot-tool](https://github.com/kagaimiq/jl-uboot-tool) (MIT). The Transporter
sends it into the FM-1's RAM each session. It's gone when the FM-1 switches off. jl-uboot-tool
doesn't say where its loaders come from.

The firmware is put back with the Transporter's web app, a single HTML page using Chrome's Web
Serial. The app writes a full flash image, and FM1Kit makes that image from M-VAVE's V15 package
and the backup the app has just taken.

What it can and can't change:

- **The Transporter's firmware writes only whole 4 KB sectors from `0x4000` to `0x92FFF`**,
  whatever it's asked. The boot area below `0x4000`, which holds the bootloader, is never written.
  Neither are the settings, voices and factory data from `0x93000` up.
- So this route can put the firmware back. It can't repair a damaged bootloader.

## What you need

- **An RP2040 board the Transporter supports.** This guide uses the Raspberry Pi Debug Probe,
  which needs no soldering. The Transporter's README also lists the Seeed XIAO RP2040 and the
  Raspberry Pi Pico.
- **A USB-C plug with its wires on screw terminals**, such as a USB-C to 5-pin terminal pigtail.
- A Mac with FM1Kit built (`swift build`), and Chrome or Edge.
- M-VAVE's official V15 package, `FM-1.fwsc`, from their downloads page.

## 1. Get the files, and check them

Download just three files: the Transporter firmware, the loader and the web app. Each is pinned
to an exact release or commit. Put them in a new, empty folder:

```sh
mkdir fm1-transporter && cd fm1-transporter
curl -LO https://github.com/kurogedelic/FM-1-transporter/releases/download/v0.1.0/fm1_transporter_debugprobe.uf2
curl -LO https://raw.githubusercontent.com/kagaimiq/jl-uboot-tool/adb3f18889e88ac512ce0a3c4d8cc3d3cb30696a/data/loaderblobs/usb/wl82loader.bin
curl -LO https://raw.githubusercontent.com/kurogedelic/FM-1-transporter/14fd4dfe08b5afb403693142b07fcb21a95092ba/web/index.html
shasum -a 256 fm1_transporter_debugprobe.uf2 wl82loader.bin index.html
```

Compare the three hashes with this table, and stop if any differs:

| File | Size | SHA-256 |
|---|---|---|
| `fm1_transporter_debugprobe.uf2` | 167,424 | `84c072366439efdacb66f44aad7719bcad0cf324d3bbdc34231c8fef5e1e5f5e` |
| `wl82loader.bin` | 24,064 | `d41da6126760c9d66660bcc0cac8d27d221806c5e369a8036921efe68dca5376` |
| `index.html` | 9,598 | `852af76ccb1463d34ed077861f7dc4c22ebc422bf0264b7dea73e72c48fa3ac3` |

Where these hashes come from:

- **The firmware's** hash is the digest GitHub records for the v0.1.0 release file.
  - That file was built by the repository's release workflow from commit `14fd4df`, which is
    the tag `v0.1.0`, using Pico SDK 2.2.0.
  - The firmware shows up on the Mac as two USB serial ports and nothing else: it doesn't act as
    a keyboard or a disk.
- **The loader's** hash matches two separate sources: jl-uboot-tool at the pinned commit, and
  the hash pinned by the [MvaveFM1Unbricker](https://github.com/Quixotic7/MvaveFM1Unbricker)
  project.
- **The web app** is that same commit's `web/index.html`. It loads nothing from the network.
  - Use this local copy rather than the hosted page, which can change at any time.

Check the V15 package too:

```sh
swift run fm1probe inspect FM-1.fwsc
```

Its product should be `FM-1_015`, with SHA-256
`db1642b2b6fa5c2cccb11ffd13878068bb28601678d3644049f99dc40e7edb8a`.

## 2. Put the Transporter firmware on the Debug Probe

1. Open the Debug Probe's lid.
2. Hold its BOOTSEL button while plugging it into the Mac. A drive named `RPI-RP2` appears.
3. Drag `fm1_transporter_debugprobe.uf2` onto that drive. The probe restarts as the Transporter.

The RP2040's own boot loader is in ROM, so this can't stop the probe being reflashed later.
[Step 7](#7-put-the-debug-probe-back) puts its usual firmware back.

## 3. Wire the FM-1's USB-C plug to the probe

Use the probe's **UART** connector, the one marked U:

| Pigtail terminal | Debug Probe (UART) |
|---|---|
| D+ | TX |
| D− | RX |
| − (GND) | GND |
| + (VBUS) | not connected |
| shield | not connected |

On a pigtail whose terminals are labelled by symbol, the shield is often the squiggle.

- **Power the FM-1 from its own battery or charger, not through this plug.** VBUS stays
  unconnected.
- With the FM-1 switched off, plug the pigtail into it.

## 4. Open the web app

Serve the folder from your own Mac. Chrome only allows Web Serial on secure pages, and
`localhost` counts as one:

```sh
python3 -m http.server 8000 --bind 127.0.0.1
```

Then open <http://localhost:8000/index.html> in Chrome or Edge.

1. **Connect:** pick the Transporter's second serial port. If it says to pick the other one,
   do that.
2. **Loader:** choose `wl82loader.bin`. It should show Loaded.
3. **FM-1:** for an FM-1 that shows nothing, keep it switched off.
   1. Press **Reconnect**.
   2. Pick the port again, and choose the loader again.
   3. Switch the FM-1 on, then press **Check**.

   It should show `key=980F` and `id=856014`. The app stops for any other chip.

   > **Note:** this version of the app only accepts the first FM-1s' flash chip, `856014`. It
   > refuses the newer chip (`B36014`), so FM-1s that have it can't be recovered with it yet.
4. **Backup:** the app reads the whole flash twice. If both reads match, it saves the flash as
   `fm1-backup-….bin` in your downloads.
   - Keep that file somewhere safe.
   - **Leave this tab open:** the app writes only if the FM-1 still matches the backup taken in
     this tab.

## 5. Make the V15 image

Look at what the backup holds, then make the image from it. Use the flash ID that Check showed:

```sh
swift run fm1probe inspect ~/Downloads/fm1-backup-….bin
swift run fm1probe flash-image FM-1.fwsc ~/Downloads/fm1-backup-….bin v15-image.bin --flash-id 856014
```

`flash-image` doesn't talk to the FM-1. It prints:

- what the backup holds;
- the sectors that will change, all inside `0x04000`–`0x92FFF`;
- the image's SHA-256.

Outside that range, the image is the backup unchanged. The command stops if the package isn't
a firmware for this chip key, or if it reaches past what the Transporter writes.

## 6. Write V15

1. In the web app's **Write** step, choose `v15-image.bin`, press **Write**, and confirm.
   - The app reads the flash first and stops if it no longer matches the backup.
   - It then writes only the sectors that differ, and reads everything back to check them.
2. **Don't switch the FM-1 off until it says Done.** If the check fails, write again.
3. When it says Done, switch the FM-1 off, wait 5 seconds, unplug the pigtail and switch it on.
   V15 should start. Its voices can be restored with `fm1probe restore-voices FM-1.fwsc` if
   they need it.

Then install [m-bootloader](https://github.com/jvitkauskas/m-bootloader) from V15 with
`fm1probe install-bootloader fm1-uboot.fwsc`. With it, holding REC while switching on starts
download mode however damaged the firmware is, so FM1Rescue can restore a backup next time
without the Transporter.

## 7. Put the Debug Probe back

1. Download `debugprobe.uf2` from Raspberry Pi's
   [debugprobe releases](https://github.com/raspberrypi/debugprobe/releases).
2. Hold BOOTSEL while plugging the probe in.
3. Drag the file onto `RPI-RP2`.

It's a Debug Probe again, with SWD and its UART bridge.
