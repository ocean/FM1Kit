# Bundled files

`mflr-loader-a.bin` and `mflr-loader-b.bin` are the flash loader that runs on the FM-1's chip in
its USB download mode, built for RAM `0x01C20000` and `0x01C28000`. They're byte-identical to the
files in m-bootloader's release
[v1.2](https://github.com/jvitkauskas/m-bootloader/releases/tag/v1.2), as its `SHA256SUMS` lists
them:

```
7286e044586ba693d0c3bacd4a05aa44cee090dd30c085caebe0db8421000794  mflr-loader-a.bin
ab35a1ff14d9eceb57055311bfff1d10a87cd21fee8f6628ce0261d580f383f9  mflr-loader-b.bin
```

FM1Kit's `ApplicationArea.swift`, which `FlashBackup+Firmware.swift` uses, reads the app area's
file table and cipher as M-Flasher's `formats.rs` (in the same repository) does, ported to Swift. `FlashPlan.swift`,
`FlashPlan+Firmware.swift` and `FlashSession+Write.swift` port M-Flasher's planning and writing
(`ops.rs`, `jl.rs` and `formats.rs`).

MIT License, Copyright (c) 2026 Julius Vitkauskas:

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
associated documentation files (the "Software"), to deal in the Software without restriction,
including without limitation the rights to use, copy, modify, merge, publish, distribute,
sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT
NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
