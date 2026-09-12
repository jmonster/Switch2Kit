#!/bin/bash
# A standalone host bundle with its own Bluetooth usage string and no restricted entitlements.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
[ "$(uname -s)" = Darwin ] || { echo 'The Switch2Kit demo requires macOS and Xcode.' >&2; exit 2; }
swift build -c release --product Switch2KitDemo
BIN=$(swift build -c release --show-bin-path)
OUT="$ROOT/build/Switch2KitDemo.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"
cp "$BIN/Switch2KitDemo" "$OUT/Contents/MacOS/Switch2KitDemo"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.switch2kit.demo</string>
<key>CFBundleExecutable</key><string>Switch2KitDemo</string>
<key>CFBundleName</key><string>Switch2Kit Demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Discover Nintendo controllers and use their buttons and sticks inside this demonstration application.</string>
</dict></plist>
PLIST
plutil -lint "$OUT/Contents/Info.plist"
codesign --force --sign - "$OUT"
codesign --verify --strict "$OUT"
echo "Built standalone, ad-hoc-signed demonstration: $OUT"
