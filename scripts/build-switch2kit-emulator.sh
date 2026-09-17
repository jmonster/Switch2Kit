#!/bin/bash
# Build an explicitly patched, pinned macOS emulator checkout.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo 'A macOS Xcode environment is required.' >&2; exit 2; }
[ "$#" -ge 3 ] || { echo "Usage: $0 dolphin|cemu /path/to/patched/source /path/to/build [CMake options...]" >&2; exit 2; }
emulator=$1; source=$2; build=$3; shift 3
python3 "$root/Integrations/Emulators/apply.py" "$emulator" "$source" --verify
xcodebuild -version
swift --version
args=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
      -DENABLE_SWITCH2KIT=ON "-DSWITCH2KIT_SOURCE_DIR=$root")
case "$emulator" in
  dolphin) args+=(-DENABLE_SDL=ON -DENABLE_QT=ON); target=dolphin-emu ;;
  cemu) args+=(-DENABLE_SDL=ON -DMACOS_BUNDLE=ON); target=CemuBin ;;
  *) echo 'Unknown emulator' >&2; exit 2 ;;
esac
cmake -S "$source" -B "$build" "${args[@]}" "$@"
cmake --build "$build" --target "$target" --parallel "${S2K_BUILD_JOBS:-4}"
python3 "$root/scripts/verify-distribution-notices.py" "$emulator" "$source" "$build"
