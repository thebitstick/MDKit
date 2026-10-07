# MDKit

A native macOS (SwiftUI) app for writing music to **NetMD** MiniDisc recorders — a from-scratch Swift port of the
device layer of [Web MiniDisc Pro](https://github.com/asivery/webminidisc) / [netmd-js](https://github.com/cybercase/netmd-js).
No browser, WebUSB or Chromium required.

## What works
- Detects and connects to any NetMD unit in the netmd-js device table (USB via libusb)
- Reads disc title, tracks, groups, durations, SP/LP2/LP4 and copy-protection flags, and capacity
- Upload (queue, drag & drop, ⌘O) in **SP** (PCM), **LP2** and **LP4** (ATRAC3 via bundled `atracdenc`);
  pre-encoded ATRAC3 `.wav`/`.at3` files are sent as-is
- Any format macOS can decode (MP3, AAC, FLAC, ALAC, WAV, AIFF…); Ogg/Opus if `ffmpeg` is installed
- Rename disc / tracks / groups, create & remove groups, reorder, move tracks between groups, delete, erase, eject
- Playback controls (play/pause/stop/prev/next, double-click a track)

## Not (yet) included
Hi-MD, MZ-RH1 track download/export, factory-mode features (firmware/TOC tools), Remote NetMD, mono SP upload,
song recognition. The protocol code for RH1 download exists in `NetMDInterface.saveTrack` but has no UI.

## Building
Requirements: Xcode / Swift 5.9+, CMake, and `brew install libusb` (linked statically).

```sh
./Scripts/build-app.sh      # builds atracdenc (first run) + the .app into build/
open "build/MDKit.app"
swift test                  # unit tests (query codec, DES, titles, ATRAC3 import pipeline)
```
`LIBUSB_PREFIX=/usr/local` overrides the libusb location on Intel Macs. The build is host-architecture only
(Homebrew's libusb is single-arch).

`Scripts/build-atracdenc.sh` builds [atracdenc](https://github.com/dcherednik/atracdenc) as a universal binary with a
tiny built-in WAV reader/writer (`Vendor/patches/pcm_io_wav16.cpp`) instead of libsndfile, so it has no dylib dependencies.

## Layout
- `Sources/NetMDKit` — protocol library: libusb transport, query codec, commands, secure-session upload, titles, groups, audio import
- `Sources/MDKit` — SwiftUI app (`DeviceController` serialises all USB I/O on one queue)

## Status / caveats
Written without access to a NetMD recorder: everything that can be tested off-device is covered by unit tests
(including the DES/3DES primitives and the encode pipeline), but the USB protocol port has **not yet been exercised against hardware**.
Try it with a disc you don't care about first, and compare against Web MiniDisc Pro if something misbehaves.

Licensed GPL-2.0 like upstream (atracdenc is LGPL-2.1, libusb LGPL-2.1).
