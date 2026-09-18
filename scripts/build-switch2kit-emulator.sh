#!/bin/bash
# Build an explicitly patched, pinned macOS or Linux emulator checkout.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
platform=$(uname -s)
case "$platform" in
  Darwin) xcodebuild -version ;;
  Linux) ;;
  *) echo 'A macOS Xcode or Linux Swift environment is required.' >&2; exit 2 ;;
esac
[ "$#" -ge 3 ] || { echo "Usage: $0 dolphin|cemu /path/to/patched/source /path/to/build [CMake options...]" >&2; exit 2; }
emulator=$1; source=$2; build=$3; shift 3
python3 "$root/Integrations/Emulators/apply.py" "$emulator" "$source" --verify
swift --version
args=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
      -DENABLE_SWITCH2KIT=ON -DSWITCH2KIT_VERIFY_SDL=ON "-DSWITCH2KIT_SOURCE_DIR=$root")
if [ "$platform" = Darwin ]; then args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0); fi
case "$emulator" in
  dolphin) args+=(-DENABLE_SDL=ON -DENABLE_QT=ON); target=dolphin-emu ;;
  cemu)
    args+=(-DENABLE_SDL=ON); target=CemuBin
    if [ "$platform" = Darwin ]; then args+=(-DMACOS_BUNDLE=ON); fi ;;
  *) echo 'Unknown emulator' >&2; exit 2 ;;
esac
cmake -S "$source" -B "$build" "${args[@]}" "$@"
cmake --build "$build" --target Switch2KitSDLVersion --parallel "${S2K_BUILD_JOBS:-4}"
"$build/switch2kit-verify/Switch2KitSDLVersion" 3004016 | tee "$build/integration-sdl-version.txt"
# A Linux install includes all enabled upstream targets (for example Dolphin's
# command-line tools), not just the GUI executable. Build them before advertising
# cmake --install. macOS retains its existing targeted bundle workflow.
if [ "$platform" = Linux ]; then
  cmake --build "$build" --parallel "${S2K_BUILD_JOBS:-4}"
else
  cmake --build "$build" --target "$target" --parallel "${S2K_BUILD_JOBS:-4}"
fi
if [ "$platform" = Darwin ]; then
  python3 "$root/scripts/verify-distribution-notices.py" "$emulator" "$source" "$build"
else
  echo 'Linux build complete. Install with cmake --install; the host requires compatible Swift runtime libraries.'
fi
