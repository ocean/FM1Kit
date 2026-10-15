# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Hardware reports are especially useful

The update timings in `UpdaterTiming` follow the FM-1-RE protocol notes and haven't been tuned
on many devices yet. If you install firmware with FM1Kit, please open an issue saying:

- the device's identity before and after (`swift run fm1probe identify`);
- the host (iPhone model and iOS version, or Mac and macOS version) and the cable or adapter;
- whether it worked, and any `UpdateEvent.log` messages or errors.

## Pull requests

- Run `swift test` before opening one; CI also builds for iOS.
- Keep FM1Kit about the device: protocol, packages, transports and installing. Firmware
  catalogues, downloads and UI belong in apps built on it.
- Match the surrounding style: Australian/British spelling in names and comments, comments
  ending in a full stop, and doc comments on everything public.
- Never add M-VAVE's firmware files, or code copied from GPL-licensed installers.
