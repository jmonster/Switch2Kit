"""Configure real CMake bundle metadata; no Apple linker or Bluetooth required."""
from pathlib import Path
import plistlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BundleTests(unittest.TestCase):
    def prepare_copy(self, paths, failure=None):
        with tempfile.TemporaryDirectory(prefix='Native bundle with spaces ') as temporary:
            root = Path(temporary)
            original = root / 'source library.dylib'
            original.write_bytes(b'Original source build must not change')
            library = root / 'Host.app/Contents/Frameworks/libSwitch2KitC.dylib'
            library.parent.mkdir(parents=True)
            library.write_bytes(original.read_bytes())
            tools = root / 'tools'
            tools.mkdir()
            log = root / 'calls.jsonl'
            commands = ''.join('Load command %d\n          cmd LC_RPATH\n      cmdsize 128\n         path %s (offset 12)\n' %
                               (i, path) for i, path in enumerate(paths))
            if failure == 'malformed':
                commands += '          cmd LC_RPATH\n      cmdsize 12\n'
            tool = tools / 'xcrun'
            tool.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['TOOL_LOG'], 'a') as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1] == "otool":
    print(os.environ['LOAD_COMMANDS'])
    sys.exit(1 if os.environ['TOOL_FAILURE'] == 'inspect' else 0)
if sys.argv[1] == "install_name_tool":
    sys.exit(1 if os.environ['TOOL_FAILURE'] == 'edit' else 0)
sys.exit(2)
''')
            tool.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                               TOOL_LOG=str(log), LOAD_COMMANDS=commands, TOOL_FAILURE=failure or '')
            result = subprocess.run(['cmake', '-DS2K_BUNDLE_LIBRARY=' + str(library), '-P',
                                     str(ROOT / 'Integrations/CMake/PrepareBundle.cmake')], env=environment,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            self.assertEqual(original.read_bytes(), b'Original source build must not change')
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(calls[0], ['otool', '-l', str(library)])
            self.assertTrue(all(call[-1] == str(library) for call in calls))
            if failure:
                self.assertNotEqual(result.returncode, 0, result.stdout)
                if failure != 'edit':
                    self.assertEqual(len(calls), 1)
            else:
                self.assertEqual(result.returncode, 0, result.stdout)
            return calls[1:]

    def test_only_build_machine_runtime_paths_are_removed_from_the_copy(self):
        external = '/Applications/Xcode Test.app/Toolchains/swift-6.2/macosx'
        paths = ['/usr/lib/swift', '@loader_path', '@executable_path/../Frameworks',
                 '/System/Library/Frameworks', external, external, '/usr/library/not-system']
        calls = self.prepare_copy(paths)
        self.assertEqual([call[:3] for call in calls], [
            ['install_name_tool', '-delete_rpath', external],
            ['install_name_tool', '-delete_rpath', '/usr/library/not-system']])

    def test_bundle_preparation_fails_closed_on_tool_or_format_errors(self):
        for failure in ('inspect', 'edit', 'malformed'):
            with self.subTest(failure=failure):
                self.prepare_copy(['/build/toolchain'], failure)

    def test_bundle_without_external_runtime_paths_is_unchanged(self):
        for paths in ([], ['/usr/lib/swift', '@loader_path']):
            self.assertEqual(self.prepare_copy(paths), [])

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
