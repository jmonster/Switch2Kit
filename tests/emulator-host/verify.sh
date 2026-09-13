#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
: "${S2K_SDL_SOURCE:?Set S2K_SDL_SOURCE to the pinned SDL source checkout}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
args=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=-fno-exceptions "-DS2K_SDL_SOURCE=$S2K_SDL_SOURCE")
if [ "$(uname -s)" = Darwin ]; then
  args+=(-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0)
else
  args+=(-DSDL_UNIX_CONSOLE_BUILD=ON)
fi
cmake -S "$root/tests/emulator-host" -B "$work" "${args[@]}"
cmake --build "$work" --parallel 4
ctest --test-dir "$work" --output-on-failure
