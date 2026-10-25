# Third-party notices

MDKit is GPL-2.0 ([LICENSE.md](LICENSE.md)). It includes, links, or is ported from the following.

## Included in the app

| Component | License | How |
|---|---|---|
| **atracdenc** (Daniil Cherednik) | LGPL-2.1 | Built from source by `Scripts/build-atracdenc.sh` and bundled as a separate executable, with a small WAV reader/writer (`Vendor/patches/pcm_io_wav16.cpp`) replacing libsndfile |
| **libusb** | LGPL-2.1 | Linked statically from Homebrew's static library |
| **Keystone** | GPL-2.0 | Linked statically from Homebrew's static library |

## Ported (protocol logic, reimplemented in Swift)

- **Web MiniDisc Pro** (asivery), GPL-2.0: the NetMD command set, device table, and secure-session handling.
- **netmd-js** (Stefano Brilli), GPL-2.0: the same protocol layer, in its original form.
- **netmd-exploits** and **netmd-tocmanip** (asivery): factory mode, firmware patches, UTOC parsing, and the
  sector-recovery algorithm behind homebrew mode ripping.

## Optional, not bundled

- **ffmpeg**: used if installed, to import Ogg/Opus and to decode ripped ATRAC1 (SP) tracks to WAV. Never shipped
  with MDKit.

## Trademarks

MiniDisc, NetMD, ATRAC, and SonicStage are trademarks of Sony. MDKit is not affiliated with or endorsed by Sony,
Sharp, Panasonic, or any other recorder maker.
