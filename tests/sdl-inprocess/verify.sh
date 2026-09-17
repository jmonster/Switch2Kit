#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
: "${S2K_SDL_SOURCE:?Set S2K_SDL_SOURCE to the SDL source checkout}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cmake -S "$ROOT/tests/sdl-inprocess" -B "$WORK" -DCMAKE_BUILD_TYPE=Release -DS2K_SDL_SOURCE="$S2K_SDL_SOURCE" -DS2K_EXPECT_SDL_VERSION="${S2K_EXPECT_SDL_VERSION:-}"
cmake --build "$WORK" --parallel 3 --target sdl-inprocess sdl-motion Switch2KitSDLVersion
ctest --test-dir "$WORK" --output-on-failure
