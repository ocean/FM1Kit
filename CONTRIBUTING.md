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
- Update the docs a change affects: README.md, the DocC articles, `llms-full.txt` (and
  `llms.txt` for a release) and CHANGELOG.md's Unreleased section.
- Keep FM1Kit about the device: protocol, packages, transports and installing. Firmware
  catalogues, downloads and UI belong in apps built on it.
- Match the surrounding style: Australian/British spelling in names and comments, comments
  ending in a full stop, and doc comments on everything public.
- Never add M-VAVE's firmware files, or code copied from GPL-licensed installers.

## Releasing

Releases are Drew's call. For each one:

1. Set `fm1probeVersion` in `Sources/fm1probe/Usage.swift` to the release's number, such as
   `0.7.0`, and move CHANGELOG.md's Unreleased section under it.
2. Update `llms.txt` and `llms-full.txt`, then tag the release with its number alone (no `v`).
3. Publish the release on GitHub. The Release workflow checks the tag matches `fm1probeVersion`,
   then opens a pull request in [ocean/homebrew-tap](https://github.com/ocean/homebrew-tap) that
   points `Formula/fm1probe.rb` at the tag's source archive. The tap's Tests workflow builds and
   tests the formula on that pull request; merge it once they pass. Pre-releases stay out of the
   tap.
4. Set `fm1probeVersion` to the next number with `-dev`, such as `0.8.0-dev`.

The formula has no `url` yet, so the Release workflow can't update it for the first release with
`fm1probe --version`. For that one, set the `url` and `sha256` by hand, then check them with
`brew install --build-from-source ocean/tap/fm1probe` and `brew test fm1probe`. Before it, create
a fine-grained personal access token limited to ocean/homebrew-tap, with read and write access to
contents and pull requests, and store it as `HOMEBREW_TAP_TOKEN` in a `homebrew-tap` environment
whose deployment rule allows only tags.
