/// What fm1probe can do, shown for `help` or arguments it doesn't understand.
let usage = """
    usage: fm1probe ports                      list MIDI port pairs and which would be probed
           fm1probe devices                    list every FM-1 that answers, numbered for --device
           fm1probe identify [options]         ask the connected FM-1 what it's running
               --repeat N                      ask N times and report timings and failures
               --port NAME                     ask this port even if its name doesn't look like an FM-1
           fm1probe monitor [SECONDS]          print every SysEx message any port sends (default 30 s);
                                               sends nothing
           fm1probe watch [SECONDS]            print the ports each time devices come or go (default 60 s)
           fm1probe inspect FILE               show a package's identity, size and hash, or which
                                               m-bootloader a .boot file or installer package holds,
                                               or the bootloader and firmware in a flash backup (.bin)
           fm1probe install FILE.fwsc [options]
                                               write a firmware to the FM-1, after asking to confirm
               --resume                        finish an update on an FM-1 waiting in its update loader
               --simulated                     run against a simulated FM-1 instead (writes nothing)
               --log FILE                      write every message to and from the device to a new
                                               CSV file
               --build-id HEX                  the package's build ID, for M-VAVE's open firmware
                                               (official releases' are known)
           fm1probe restore-voices FM-1.fwsc [options]
                                               rewrite V15's four voice banks with its factory voices,
                                               from the official V15 package, after asking to confirm
               --simulated                     run against a simulated FM-1 running V15 (writes nothing)
               --log FILE                      write every message to and from the device to a new
                                               CSV file
           fm1probe install-bootloader fm1-uboot.fwsc [options]
                                               install m-bootloader from its installer package on an
                                               FM-1 running V15, after asking to confirm
               --simulated                     run against a simulated FM-1 running V15 (writes nothing)
               --from-any-firmware             send it whatever firmware is running (hardware tests)
               --log FILE                      write every message to and from the device to a new
                                               CSV file
           fm1probe download-mode              ask the FM-1 (V15 or Felucca) to restart into the chip's
                                               USB download mode; nothing is written
           fm1probe flash-backup FOLDER [options]
                                               read the whole flash of an FM-1 in download mode, twice,
                                               and save it as M-Flasher does; needs sudo
               --simulated                     read a simulated FM-1 instead
               --trace                         print every USB transfer
           fm1probe flash-restore BACKUP.bin FOLDER [options]
                                               put a full flash backup back on an FM-1 in download
                                               mode; another FM-1's keeps this one's factory data
           fm1probe flash-bootloader FILE FOLDER [options]
                                               install a bootloader in download mode: m-bootloader
                                               from a .boot file or fm1-uboot.fwsc, or M-VAVE's from
                                               a firmware package such as V15's
           fm1probe flash-install FILE.fwsc FOLDER [options]
                                               install a firmware in download mode, keeping the
                                               bootloader, settings and voices
               --with-bootloader               also write the package's bootloader
               --erase-settings                also erase the firmware's settings and Bluetooth pairings
                                               Each reads the flash and saves it to FOLDER first, shows
                                               what changes, and writes only after you type YES; it
                                               then checks every change. Needs sudo.
               --simulated BACKUP.bin          run against a simulated FM-1 holding this backup
               --trace                         print every USB transfer
           fm1probe backup FOLDER [options]    save the projects and sample bank of an FM-1 running
                                               M-VAVE's open firmware to a new folder, after asking
                                               to confirm
               --simulated                     run against a simulated FM-1 running open firmware
               --log FILE                      write every message to and from the device to a new
                                               CSV file

    With more than one FM-1 connected, install, install-bootloader, restore-voices, backup and
    download-mode need --device N (as `fm1probe devices` numbers them) or --device SERIAL.
    """
