# AGENTS.md

Guidance for AI agents (and contributors) working in this repository.

## What this is

MDKit: a native macOS SwiftUI app (macOS 13+, SwiftPM, Apple Silicon only) for NetMD MiniDisc recorders. It writes
music to a disc and reads tracks back off decks that never supported it ("homebrew mode ripping"). GPL-2.0. Bundle ID
`rip.bitstick.MDKit`. The code is AI-written; keep `AI-DISCLOSURE.md` truthful when that changes.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/MDKit/` | the SwiftUI app. `DeviceController` serialises all USB I/O onto one queue |
| `Sources/NetMDKit/` | everything that is not UI, and what the tests cover: USB transport, NetMD commands, factory mode, firmware assembly, ripping |
| `Sources/CLibUSB/`, `Sources/CKeystone/` | system-library shims for Homebrew's libusb and Keystone (linked statically) |
| `Tests/NetMDKitTests/` | the tests; no hardware needed |
| `Resources/` | `Info.plist`, `AppIcon.icns`, `icon-readme.png` |
| `Scripts/` | `build-app.sh`, `package.sh`, `build-atracdenc.sh` |
| `Vendor/patches/` | WAV reader/writer swapped into atracdenc in place of libsndfile |
| `docs/` | README images |

## Commands

```
brew install libusb keystone cmake
swift build
swift test                       # 25 tests, a few seconds, no hardware
MDKIT_HARDWARE=1 ATRACDENC_PATH=build/atracdenc swift test --filter HardwareTests   # ~3 min; BLANK disc in a real deck, MDKit quit
Scripts/build-app.sh             # build/MDKit.app, release, arm64, ad-hoc signed (builds atracdenc on first run)
Scripts/package.sh               # then build/release/*.zip, *.dmg, SHA256SUMS.txt
```

Releases: bump `CFBundleShortVersionString` in `Resources/Info.plist`, then push a `v*` tag. The `release` workflow
tests, packages and publishes. The `check` workflow runs on every push.

## Rules

- **Never quit, kill or rebuild over a running MDKit** (`pkill`, or `Scripts/build-app.sh`, which replaces
  `build/MDKit.app`) without asking, or checking with a screenshot that it is idle. The user may be mid-rip, and
  interrupting one can leave the deck in an odd state. Use `swift build` / `swift test` (they write to `.build/`)
  while the app is open.
- **Don't write to a real deck without the user's go-ahead.** `HardwareTests` only runs on a blank disc and deletes only what it recorded. Hardware behaviour was learned the hard way; see below.
- Ask before publishing anything (repo visibility, tags, releases).
- Swift concurrency warnings are bugs: keep the build warning-free. `NetMDInterface` and `HomebrewRipper` are
  `@unchecked Sendable` because the app serialises every call on one queue.

## Design decisions to preserve

- **Firmware patches are applied atomically.** The control-transfer backend's two redirects and its resident handler
  go in as one injected program (`FirmwareAssembler.assembleControlInstaller`). Applying them as separate host-side
  steps leaves a window where the deck's background USB polling hits a half-installed redirect and hangs.
- **Patches are RAM-only** and vanish on disconnect or power cycle. Nothing is written to the deck's EEPROM.
- **A failed transfer stops the batch**, for both uploads and rips: the unit may be mid-seek or mid-realignment, and
  racing into the next track's sequence on top of that is worse than stopping.
- **Status polling pauses during uploads and rips** (`activeOps`, `isUploading`, `isRipping`).
- The control-transfer ripping backend is Type-S only. Upstream found Type-R decks unstable with it.
- SP rips come out as ATRAC1 (AEA) and are decoded to WAV via ffmpeg when available, since nothing on macOS plays AEA.
- `Scripts/build-atracdenc.sh` pins atracdenc to a commit. Bump it deliberately and re-test an LP2/LP4 upload.
- The build is arm64 only. Don't add universal-build plumbing.

## Verifying UI

`screencapture -x -o -l <windowID>` with an ID from `CGWindowListCopyWindowInfo`. Don't kill the app to do it.
