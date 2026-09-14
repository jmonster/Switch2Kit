#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
: "${S2K_SDL_SOURCE:?Set S2K_SDL_SOURCE to the SDL source checkout}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cmake -S "$ROOT/tests/sdl-inprocess" -B "$WORK" -DCMAKE_BUILD_TYPE=Release -DS2K_SDL_SOURCE="$S2K_SDL_SOURCE"
cmake --build "$WORK" --parallel 3 --target sdl-inprocess sdl-motion
ctest --test-dir "$WORK" --output-on-failure
