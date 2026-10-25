# AI disclosure

This project was built with AI assistance.

## What the AI did

Most of the code and documentation here was written by **Claude** (Anthropic, run through Claude Code) in a
back-and-forth session with the project's author: the Swift port of the NetMD device layer, the SwiftUI app, the
homebrew-mode ripping port (including the firmware assembler and sector-recovery logic), the tests, the build and
packaging scripts, the CI workflows, and the app icon (drawn as an SVG and converted with ImageMagick). Commits made
with Claude's help carry a `Co-Authored-By: Claude` trailer.

## What the human did

The author decided what to build, supplied the hardware (a Sony NetMD deck), ran every build against it, and reported
what failed. The ripping backend was debugged that way, through several rounds of real device errors.

## What was tested

- `swift test`: protocol codec round-trips, DES known-answer vectors, title sanitising, ARM assembly for every known
  firmware version, group compilation, and ATRAC1-to-WAV decoding. No hardware needed.
- On one real Sony NetMD deck: uploads, and full-track homebrew-mode rips (control-transfer backend).

## What was not tested

- Any other deck or firmware version, including every other entry in the firmware tables and the Type-R and no-RAM
  ripping paths.
- Intel Macs (unsupported), and macOS versions other than the author's.
- The release workflow, until the first tag is pushed.
