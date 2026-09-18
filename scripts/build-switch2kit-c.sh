#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
fail() { echo "Switch2Kit C: $*" >&2; exit 2; }
[ "$(uname -s)" = Darwin ] || fail 'Universal distribution requires macOS and full Xcode 26+.'
command -v xcodebuild >/dev/null || fail 'Select full Xcode using DEVELOPER_DIR.'
xcrun swift --version
xcodebuild -version
mkdir -p "$ROOT/build"
WORK=$(mktemp -d "$ROOT/build/.switch2kit-c.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
SDK=$(xcrun --sdk macosx --show-sdk-path)
BIN="$WORK/universal"
mkdir -p "$BIN"
LIB="$BIN/libSwitch2KitC.dylib"
SLICES=()
for ARCH in arm64 x86_64; do
  ARGS=(--package-path "$ROOT" --scratch-path "$WORK/swift-$ARCH" -c release
        --triple "$ARCH-apple-macosx15.0" --sdk "$SDK")
  xcrun swift build "${ARGS[@]}" --product Switch2KitC
  ARCH_BIN=$(xcrun swift build "${ARGS[@]}" --show-bin-path)
  SLICES+=("$ARCH_BIN/libSwitch2KitC.dylib")
done
lipo -create "${SLICES[@]}" -output "$LIB"
file "$LIB"
lipo "$LIB" -verify_arch arm64 x86_64
if otool -L "$LIB" | grep -E 'CoreHID|Switch2KitApp'; then fail 'Unexpected application dependency.'; fi
nm -gjU "$LIB" > "$WORK/exports"
for symbol in s2k_create s2k_destroy s2k_read s2k_start s2k_stop s2k_play_feedback s2k_set_rumble s2k_convert_motion s2k_decode_motion_profile s2k_motion_profile_calibration s2k_monotonic_time; do
  grep -qx "_$symbol" "$WORK/exports" || fail "Missing C symbol: $symbol"
done
if grep -q s2k_fixture "$WORK/exports"; then fail 'Test fixture leaked into the library.'; fi
# Pure C++ source: no Swift types, generated Swift header or compiled Swift module import.
cat > "$WORK/main.cpp" <<'CPP'
#include <Switch2KitC.h>
#include <Switch2KitMotion.h>
#include <Switch2KitMotionProfile.h>
#include <cassert>
int main() {
    assert(s2k_abi_version() == S2K_ABI_VERSION);
    S2KState state{};
    state.present = S2K_HAS_MOTION; state.accel[0] = 2;
    S2KMotionCalibration profile{};
    profile.version = S2K_MOTION_CALIBRATION_VERSION; profile.struct_size = sizeof(profile);
    profile.acceleration = {{0, 0, 0}, {1, 1, 1}, {1, 2, 3}, 0};
    profile.angular_velocity = profile.acceleration;
    S2KCalibratedMotion motion{};
    assert(s2k_convert_motion(&state, &profile, &motion, sizeof(motion)) == S2K_OK);
    assert(motion.acceleration[0] == 2);
    S2KResult result{};
    auto *manager = s2k_create(nullptr, &result);
    assert(manager && result == S2K_OK);
    s2k_destroy(manager); // Creation/teardown only: does not start Bluetooth.
}
CPP
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -arch arm64 -arch x86_64 \
  -mmacosx-version-min=15.0 -I "$ROOT/Sources/Switch2KitCABI/include" \
  "$WORK/main.cpp" -L "$BIN" -lSwitch2KitC -Wl,-rpath,"$BIN" -o "$WORK/consumer"
lipo "$WORK/consumer" -verify_arch arm64 x86_64
"$WORK/consumer"
xcodebuild -create-xcframework -library "$LIB" \
  -headers "$ROOT/Sources/Switch2KitCABI/include" -output "$WORK/Switch2KitC.xcframework"
mkdir -p "$WORK/Switch2KitC.xcframework/Notices"
cp "$ROOT/CREDITS.md" "$WORK/Switch2KitC.xcframework/Notices/"
cp -R "$ROOT/LICENSES" "$WORK/Switch2KitC.xcframework/Notices/"
plutil -lint "$WORK/Switch2KitC.xcframework/Info.plist"
python3 - "$WORK/Switch2KitC.xcframework/Info.plist" <<'PY'
import plistlib,sys
p=plistlib.load(open(sys.argv[1],'rb'))
a=p['AvailableLibraries']
assert len(a)==1 and set(a[0]['SupportedArchitectures'])=={'arm64','x86_64'}
assert a[0]['SupportedPlatform']=='macos'
PY
rm -rf "$ROOT/build/Switch2KitC.xcframework"
mv "$WORK/Switch2KitC.xcframework" "$ROOT/build/"
rm -f "$ROOT/build/Switch2KitC.xcframework.zip"
ditto -c -k --keepParent "$ROOT/build/Switch2KitC.xcframework" "$ROOT/build/Switch2KitC.xcframework.zip"
(cd "$ROOT/build" && shasum -a 256 Switch2KitC.xcframework.zip > Switch2KitC.xcframework.zip.sha256)
echo 'PASS universal C ABI, exported symbols, dependencies, fresh C++ consumers and XCFramework structure'
