#!/bin/bash
# Build a patched SDL library without changing the supplied source checkout.
# Usage: bash sdl/build-sdl.sh /path/to/SDL-git-checkout
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source_dir=${1:?Provide a git checkout of libsdl-org/SDL containing release-3.4.16}
revision=fa2c02bb6e21974a89ea9824bc53c9932abe5f9c
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git -C "$source_dir" archive "$revision" | tar -x -C "$work"
git -C "$work" apply "$root/sdl/sdl3-s2udp.patch"
git -C "$work" apply "$root/sdl/s2udp-input-edges.patch"
git -C "$work" apply "$root/sdl/s2usb-device-identity.patch"
git -C "$work" apply "$root/sdl/s2udp-pro-controller.patch"
cmake -S "$work" -B "$work/build" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_HIDAPI_LIBUSB=ON
cmake --build "$work/build" --parallel 3
mkdir -p "$root/build/sdl"
cp "$work/build/libSDL3.0.dylib" "$root/build/sdl/libSDL3.0.dylib"
shasum -a 256 "$root/build/sdl/libSDL3.0.dylib"
