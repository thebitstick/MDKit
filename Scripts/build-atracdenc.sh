#!/bin/bash
# Builds a self-contained atracdenc (ATRAC3 encoder) with a WAV-only PCM backend.
# Output: build/atracdenc
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/atracdenc-src"
# Pinned so builds are reproducible and upstream changes can't silently alter the bundled encoder.
# To update: bump this, rebuild, and re-run an LP2/LP4 upload test.
ATRACDENC_COMMIT=cb170709f836cb43dc0312455188c791159d81dc
mkdir -p "$ROOT/build"
if [ ! -d "$WORK" ]; then
  git clone https://github.com/dcherednik/atracdenc.git "$WORK"
fi
git -C "$WORK" fetch --quiet origin "$ATRACDENC_COMMIT" 2>/dev/null || true
git -C "$WORK" checkout --quiet "$ATRACDENC_COMMIT"
git -C "$WORK" submodule update --init --recursive --quiet
cp "$ROOT/Vendor/patches/pcm_io_wav16.cpp" "$WORK/src/pcm_io_wav16.cpp"
# Swap the libsndfile backend for the bundled WAV one.
python3 - "$WORK/src/CMakeLists.txt" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if "pcm_io_wav16" not in s:
    s = re.sub(r'    INCLUDE\(FindLibSndFile\).*?pcm_io_sndfile\.cpp\n    \)',
               '    set(PCM_IO_LIBRARIES)\n    set(SOURCE_PCM_IO_LIB\n        pcm_io_wav16.cpp\n    )', s, count=1, flags=re.S)
    open(p, "w").write(s)
PY
cmake -S "$WORK/src" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
cmake --build "$WORK/build" -j"$(sysctl -n hw.ncpu)"
cp "$(find "$WORK/build" -name atracdenc -type f -perm -u+x | head -1)" "$ROOT/build/atracdenc"
echo "Built $ROOT/build/atracdenc"
