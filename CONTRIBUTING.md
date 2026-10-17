# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Hardware reports are especially useful

FM1Kit has been tested on one FM-1, and `UpdaterTiming` hasn't been tuned on many devices yet.
If you install firmware with FM1Kit, please open an issue saying:

- the device's identity before and after (`swift run fm1probe identify`);
- the host (iPhone model and iOS version, or Mac and macOS version) and the cable or adapter;
- the firmware installed, and whether it worked: the error if not, and ideally `fm1probe
  install`'s summary, or its `--log` file.

## Pull requests

- Run `scripts/check.sh` before opening one (it needs `brew install swiftlint periphery`). It's
  what CI runs, and it must pass with no warnings.
- Format with `swift format format --in-place --recursive Sources Tests Package.swift`.
- Add tests for new behaviour; the simulated FM-1 can stand in for the device.
- Keep FM1Kit about the device: protocol, packages, transports and installing. Firmware
  catalogues, downloads and UI belong in apps built on it.
- Match the surrounding style: Australian/British spelling in names and comments, comments
  ending in a full stop, and doc comments on everything public.
- Never add M-VAVE's firmware files, or code copied from GPL-licensed installers.
