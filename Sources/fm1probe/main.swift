// A small Mac command-line probe: talk to a real FM-1 over CoreMIDI and inspect .fwsc files.
// Only `install`, `install-bootloader`, `restore-voices`, `write-resources` and the download-mode
// `flash-restore`, `flash-bootloader` and `flash-install` write to the device, and `backup` changes
// which project it's showing while it reads; each asks the user to type YES first. `download-mode` asks the
// FM-1 to restart into the chip's download mode, and `flash-backup` reads its flash there;
// neither writes. Every other command sends nothing but the handshake query.
//
// This file holds only the top-level statements. Periphery attaches references in top-level
// code to the nearest declaration above them, so a declaration here would hide every command
// from its unused-code check; the commands are in Commands.swift.

keepOutputReachingTheTerminal()
try await runCommand()
