"""Exercise the deployment script on real native binaries, without Bluetooth or Swift.

The tiny runtime and OS libraries are fixtures, not redistributable runtime files.
The C/SDL consumer jobs separately qualify the real Swift dependency closure.
"""
from pathlib import Path
import hashlib
import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'Integrations/CMake/StageDesktopRuntime.cmake'


@unittest.skipUnless(sys.platform in ('linux', 'win32'), 'Desktop runtime deployment is Linux/Windows only')
class RuntimeStagingTests(unittest.TestCase):
    def run_command(self, *args):
        return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=60, check=False)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='s2k runtime boundary ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / 'compiler runtime'
        self.system = self.root / 'System32'
        self.app = self.root / 'application'
        self.destination = self.root / 'package'
        for name, body in {
            'leaf': 'int leaf(void) { return 1; }',
            'runtime': 'extern int leaf(void); int runtime(void) { return leaf(); }',
            'private_os': 'int private_os(void) { return 2; }',
            'system_boundary': 'extern int private_os(void); int system_boundary(void) { return private_os(); }',
            'fixture_leaf': 'int fixture_leaf(void) { return 7; }',
            'fixture': 'extern int fixture_leaf(void); int fixture(void) { return fixture_leaf(); }',
            'consumer': 'extern int facade(void); extern int fixture(void); int main(void) { return facade() + fixture() == 10 ? 0 : 1; }',
            'facade': 'extern int runtime(void); extern int system_boundary(void); int facade(void) { return runtime() + system_boundary(); }',
        }.items():
            (self.root / f'{name}.c').write_text(body + '\n')
        # Use .dll names on both platforms so the same exact-file boundary is
        # tested with native ELF on Linux and native PE on Windows.
        (self.root / 'CMakeLists.txt').write_text('''cmake_minimum_required(VERSION 3.24)
project(RuntimeBoundary C)
foreach(name leaf runtime private_os system_boundary facade fixture_leaf fixture)
  add_library(${name} SHARED ${name}.c)
  set_target_properties(${name} PROPERTIES PREFIX "" SUFFIX ".dll" WINDOWS_EXPORT_ALL_SYMBOLS ON)
endforeach()
target_link_libraries(fixture PRIVATE fixture_leaf)
add_executable(consumer consumer.c)
target_link_libraries(consumer PRIVATE facade fixture)
set_target_properties(consumer PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/application")
set_target_properties(fixture PROPERTIES
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/fixture libraries"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/fixture libraries")
target_link_libraries(runtime PRIVATE leaf)
target_link_libraries(system_boundary PRIVATE private_os)
target_link_libraries(facade PRIVATE runtime system_boundary)
foreach(name leaf runtime fixture_leaf)
  set_target_properties(${name} PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/compiler runtime"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/compiler runtime")
endforeach()
foreach(name private_os system_boundary)
  set_target_properties(${name} PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/System32"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/System32")
endforeach()
set_target_properties(facade PROPERTIES
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/facade libraries"
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/facade libraries")
''')
        for args in [
            ('cmake', '-S', str(self.root), '-B', str(self.root / 'build'), '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release'),
            ('cmake', '--build', str(self.root / 'build'), '--parallel', '2'),
        ]:
            result = self.run_command(*args)
            self.assertEqual(result.returncode, 0, result.stdout)
        # This dependency of an OS library must not be inspected or bundled.
        (self.system / 'private_os.dll').unlink()
        self.library = self.root / 'facade libraries/facade.dll'
        self.config = self.root / 'runtime.cmake'
        self.swift_license = self.root / 'fixture-license.txt'
        self.icu_license = self.root / 'fixture-icu.txt'
        self.swift_license.write_text('Native test runtime fixture license\n')
        self.icu_license.write_text('Native test ICU fixture notice\n')
        inspector = 'dumpbin' if sys.platform == 'win32' else 'objdump'
        self.assertIsNotNone(shutil.which(inspector), f'{inspector} is required')
        system_dirs = [self.system]
        if sys.platform == 'win32':
            system_root = Path(os.environ['SystemRoot'])
            system_dirs.extend([system_root / 'System32', system_root])
        values = {
            'S2K_RUNTIME_DIRS': self.runtime,
            'S2K_SYSTEM_RUNTIME_DIRS': ';'.join(path.as_posix() for path in system_dirs),
            'S2K_SWIFT_LICENSE': self.swift_license,
            'S2K_ICU_LICENSE': self.icu_license,
            'S2K_COMPILER_VERSION': 'Native fixture (not Swift)',
            'CMAKE_GET_RUNTIME_DEPENDENCIES_PLATFORM': 'windows+pe' if sys.platform == 'win32' else 'linux+elf',
            'CMAKE_GET_RUNTIME_DEPENDENCIES_TOOL': inspector,
            'CMAKE_GET_RUNTIME_DEPENDENCIES_COMMAND': Path(shutil.which(inspector)).as_posix(),
            'S2K_READELF': Path(shutil.which('readelf')).as_posix() if sys.platform == 'linux' else '',
        }
        self.config.write_text(''.join(f'set({key} [==[{value.as_posix() if isinstance(value, Path) else value}]==])\n'
                                       for key, value in values.items()))

    def stage(self, destination=None, *extra):
        return self.run_command('cmake', f'-DS2K_LIBRARY={self.library.as_posix()}',
                                f'-DS2K_DESTINATION={(destination or self.destination).as_posix()}',
                                f'-DS2K_NOTICES={(self.root / "notices").as_posix()}',
                                f'-DS2K_RUNTIME_CONFIG={self.config.as_posix()}', *extra, '-P', str(SCRIPT))

    def test_system_boundary_preserves_transitive_runtime_and_source_files(self):
        before = {path: hashlib.sha256(path.read_bytes()).digest()
                  for path in [self.library, *self.runtime.glob('*.dll')]}
        result = self.stage()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({p.name for p in self.destination.iterdir()}, {'facade.dll', 'runtime.dll', 'leaf.dll'})
        for path, digest in before.items():
            self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), digest, str(path))
        self.assertEqual((self.root / 'notices/SwiftRuntime/LICENSE.txt').read_bytes(), self.swift_license.read_bytes())
        self.assertEqual((self.root / 'notices/SwiftRuntime/ICU.txt').read_bytes(), self.icu_license.read_bytes())

    def test_missing_application_dependency_still_fails(self):
        (self.runtime / 'leaf.dll').unlink()
        result = self.stage()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('leaf.dll', result.stdout)
        self.assertFalse(self.destination.exists())

    def test_missing_system_boundary_is_not_hidden_by_name(self):
        (self.system / 'system_boundary.dll').unlink()
        result = self.stage()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('system_boundary.dll', result.stdout)
        self.assertFalse(self.destination.exists())

    def host_arguments(self):
        executable = self.app / ('consumer.exe' if sys.platform == 'win32' else 'consumer')
        fixture = self.root / 'fixture libraries/fixture.dll'
        return (f'-DS2K_EXECUTABLE={executable.as_posix()}',
                f'-DS2K_EXTRA_LIBRARIES={fixture.as_posix()}')

    def test_host_closure_includes_runtime_used_only_by_a_linked_fixture(self):
        before = {path: path.read_bytes() for path in self.runtime.glob('*.dll')}
        result = self.stage(None, *self.host_arguments())
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual({p.name for p in self.destination.iterdir()},
                         {'facade.dll', 'runtime.dll', 'leaf.dll', 'fixture.dll', 'fixture_leaf.dll'})
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content, str(path))

    def test_host_staging_is_repeatable_with_an_existing_runtime_copy(self):
        for attempt in range(2):
            with self.subTest(attempt=attempt):
                result = self.stage(self.app, *self.host_arguments())
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual((self.app / 'fixture_leaf.dll').read_bytes(),
                                 (self.runtime / 'fixture_leaf.dll').read_bytes())

    @unittest.skipUnless(sys.platform == 'win32', 'PE loader search order is Windows-specific')
    def test_stale_staged_runtime_cannot_override_the_selected_compiler(self):
        result = self.stage(self.app, *self.host_arguments())
        self.assertEqual(result.returncode, 0, result.stdout)
        staged = self.app / 'fixture_leaf.dll'
        source = self.runtime / 'fixture_leaf.dll'
        staged.write_bytes(b'X' * source.stat().st_size)
        # A stale cache can retain both file size and modification time. The
        # deployment copy must compare content rather than trust timestamps.
        source_stat = source.stat()
        os.utime(staged, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
        result = self.stage(self.app, *self.host_arguments())
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.app / 'fixture_leaf.dll').read_bytes(),
                         (self.runtime / 'fixture_leaf.dll').read_bytes())
        (self.runtime / 'fixture_leaf.dll').unlink()
        result = self.stage(self.app, *self.host_arguments())
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('fixture_leaf.dll', result.stdout)

    def test_missing_fixture_only_runtime_fails_before_packaging(self):
        (self.runtime / 'fixture_leaf.dll').unlink()
        result = self.stage(None, *self.host_arguments())
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn('fixture_leaf.dll', result.stdout)
        self.assertFalse(self.destination.exists())

    def test_missing_host_or_linked_library_is_not_ignored(self):
        for argument in ('S2K_EXECUTABLE', 'S2K_EXTRA_LIBRARIES'):
            with self.subTest(argument=argument):
                result = self.stage(None, f'-D{argument}={self.root.as_posix()}/missing')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('missing', result.stdout)
                self.assertFalse(self.destination.exists())

    @unittest.skipUnless(sys.platform == 'win32', 'Windows deployment copy lock')
    def test_missing_dependency_is_diagnosed_without_waiting_for_copy_lock(self):
        key = hashlib.sha256(self.destination.resolve().as_posix().lower().encode()).hexdigest()
        lock = Path(str(self.config) + '.' + key + '.lock')
        ready, release = self.root / 'lock ready', self.root / 'release lock'
        holder_script = self.root / 'hold-lock.cmake'
        holder_script.write_text(f'''cmake_minimum_required(VERSION 3.24)
file(LOCK "{lock.as_posix()}" GUARD PROCESS TIMEOUT 10)
file(WRITE "{ready.as_posix()}" "ready")
while(NOT EXISTS "{release.as_posix()}")
  execute_process(COMMAND "${{CMAKE_COMMAND}}" -E sleep 0.1)
endwhile()
''')
        holder = subprocess.Popen(['cmake', '-P', str(holder_script)],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 15
            while not ready.exists() and holder.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), 'The independent deployment lock was not acquired')
            (self.runtime / 'fixture_leaf.dll').unlink()
            result = self.stage(None, *self.host_arguments())
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('fixture_leaf.dll', result.stdout)
            self.assertNotIn('error locking file', result.stdout)
            self.assertIsNone(holder.poll(), 'Input validation must finish while the copy lock is still held')
            self.assertFalse(self.destination.exists())
        finally:
            release.write_text('release')
            try:
                holder.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                holder.kill()
                holder.communicate()

    def test_deployment_into_compiler_runtime_is_rejected(self):
        result = self.stage(self.runtime)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.runtime / 'facade.dll').exists())


class RuntimeNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='s2k notice cache ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.content = b'Native test fixture license; not a redistributed runtime license.\n'
        self.blob = hashlib.sha1(b'blob ' + str(len(self.content)).encode() + b'\0' + self.content).hexdigest()
        self.git = shutil.which('git')
        self.assertIsNotNone(self.git)
        self.driver = self.root / 'notice.cmake'
        self.driver.write_text(f'''cmake_minimum_required(VERSION 3.24)
set(S2K_RUNTIME_CONFIG "{self.root.as_posix()}/runtime.cmake")
set(S2K_GIT "{Path(self.git).as_posix()}")
include("{(ROOT / 'Integrations/CMake/RuntimeNotices.cmake').as_posix()}")
file(WRITE "${{READY}}" "ready")
_s2k_license("fixture.txt" "${{URL}}" "{self.blob}" acquired)
file(WRITE "${{RESULT}}" "${{acquired}}")
''')

    def launch(self, suffix, url):
        return subprocess.Popen(['cmake', f'-DREADY={self.root.as_posix()}/{suffix}.ready',
                                 f'-DRESULT={self.root.as_posix()}/{suffix}.result',
                                 f'-DURL={url}', '-P', str(self.driver)],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def test_parallel_acquisition_cannot_read_a_partial_license(self):
        entered, release = threading.Event(), threading.Event()
        requests = []
        content = self.content

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                entered.set()
                if not release.wait(20):
                    self.send_error(503)
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(content)))
                self.end_headers()
                self.wfile.write(content)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        children = []
        try:
            url = f'http://127.0.0.1:{server.server_port}/fixture.txt'
            children.append(self.launch('first', url))
            self.assertTrue(entered.wait(15), 'The first acquisition did not reach the local fixture server')
            second = self.launch('second', url)
            children.append(second)
            deadline = time.monotonic() + 15
            while not (self.root / 'second.ready').exists() and second.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue((self.root / 'second.ready').exists())
            # The first download remains incomplete until this test releases it.
            # A second caller must wait instead of hashing its partial cache file.
            with self.assertRaises(subprocess.TimeoutExpired):
                second.wait(timeout=0.5)
            release.set()
            for child in children:
                output, _ = child.communicate(timeout=30)
                self.assertEqual(child.returncode, 0, output)
            self.assertEqual(requests, ['/fixture.txt'])
            self.assertEqual((self.root / 'runtime-notices/fixture.txt').read_bytes(), self.content)
            for suffix in ('first', 'second'):
                self.assertEqual(Path((self.root / f'{suffix}.result').read_text()).read_bytes(), self.content)
        finally:
            release.set()
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.communicate()
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    def test_changed_cached_license_still_fails_hash_validation(self):
        cache = self.root / 'runtime-notices'
        cache.mkdir()
        (cache / 'fixture.txt').write_bytes(b'altered fixture license')
        child = self.launch('changed', 'http://127.0.0.1:1/not-used')
        try:
            output, _ = child.communicate(timeout=30)
            self.assertNotEqual(child.returncode, 0, output)
            self.assertIn('Altered or incorrect upstream license', output)
            self.assertFalse((self.root / 'changed.result').exists())
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate()


if __name__ == '__main__':
    unittest.main()
