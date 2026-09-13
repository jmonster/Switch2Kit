"""Configure real CMake bundle metadata; no Apple linker or Bluetooth required."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BundleTests(unittest.TestCase):
    def test_scoped_permissions_survive_bundle_generation_and_reconfigure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'main.c').write_text('int main(void) { return 0; }\n')
            (root / 'Info.plist.in').write_text('''<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>${MACOSX_BUNDLE_EXECUTABLE_NAME}</string>
<key>CFBundleIdentifier</key><string>org.example.controller-host</string>
<key>LSMinimumSystemVersion</key><string>${CMAKE_OSX_DEPLOYMENT_TARGET}</string>
${SWITCH2KIT_BLUETOOTH_USAGE}
</dict></plist>
''')
            helper = (ROOT / 'Integrations/CMake/Bundle.cmake').as_posix()
            (root / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.24)
project(BundleFixture C)
include("%s")
add_library(Switch2Kit::C SHARED IMPORTED GLOBAL)
set_target_properties(Switch2Kit::C PROPERTIES IMPORTED_LOCATION "${CMAKE_BINARY_DIR}/libSwitch2KitC.dylib")
function(add_host target enabled)
  add_executable(${target} MACOSX_BUNDLE main.c)
  set_target_properties(${target} PROPERTIES MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/Info.plist.in")
  if(enabled)
    set(SWITCH2KIT_BLUETOOTH_USAGE "<key>NSBluetoothAlwaysUsageDescription</key><string>${HOST_LABEL} uses Bluetooth for controller input.</string>")
  else()
    set(SWITCH2KIT_BLUETOOTH_USAGE "")
  endif()
  switch2kit_embed(${target})
endfunction()
add_host(controller-host ON)
add_host(no-controller-host OFF)
''' % helper)
            build = root / 'build'
            for label in ('Dolphin', 'Cemu'):
                result = subprocess.run([
                    'cmake', '-S', str(root), '-B', str(build), '-G', 'Unix Makefiles',
                    '-DCMAKE_SYSTEM_NAME=Darwin', '-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0',
                    '-DCMAKE_C_COMPILER=' + (shutil.which('clang') or shutil.which('cc')),
                    '-DCMAKE_C_COMPILER_WORKS=TRUE', '-DCMAKE_OSX_ARCHITECTURES=',
                    '-DHOST_LABEL=' + label,
                ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 0, result.stdout)
                for target, enabled in [('controller-host', True), ('no-controller-host', False)]:
                    contents = (build / (target + '.app/Contents/Info.plist')).read_bytes()
                    info = plistlib.loads(contents)
                    self.assertEqual(info['CFBundleExecutable'], target)
                    self.assertEqual(info['CFBundleIdentifier'], 'org.example.controller-host')
                    self.assertEqual(info['LSMinimumSystemVersion'], '15.0')
                    if enabled:
                        self.assertEqual(info['NSBluetoothAlwaysUsageDescription'],
                                         label + ' uses Bluetooth for controller input.')
                    else:
                        self.assertNotIn('NSBluetoothAlwaysUsageDescription', info)
                    self.assertNotIn(b'SWITCH2KIT_BLUETOOTH_USAGE', contents)


if __name__ == '__main__':
    unittest.main()
